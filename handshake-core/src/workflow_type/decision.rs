//! Portable decision questions and validated routing over Nouli's versioned reports.
use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionKind {
    #[default]
    Choice,
    Noul,
    Score,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionOption {
    pub id: String,
    pub name: String,
    pub description: String,
}

/// Thresholds use basis points (0–10,000) to keep saved workflow definitions exact.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionNode {
    pub question: String,
    #[serde(default)]
    pub kind: DecisionKind,
    #[serde(default)]
    pub options: Vec<DecisionOption>,
    #[serde(default = "yes_threshold")]
    pub true_threshold: u16,
    #[serde(default = "no_threshold")]
    pub false_threshold: u16,
    #[serde(default)]
    pub min_confidence: Option<u16>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default = "include_task")]
    pub include_task: bool,
}

const fn yes_threshold() -> u16 {
    8_000
}
const fn no_threshold() -> u16 {
    2_000
}
const fn include_task() -> bool {
    true
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DecisionResultError {
    #[error("Nouli returned an invalid or incompatible decision report.")]
    Invalid,
    #[error("Nouli refused to answer. Review the evidence before retrying.")]
    Refused,
    #[error("The configured native-confidence gate is unavailable for this answer.")]
    ConfidenceUnavailable,
}

impl DecisionNode {
    /// Connected labels stay current; imported Score rubrics retain their original meaning.
    pub(crate) fn with_connected_names(
        &self,
        definition: &super::WorkflowTypeDefinition,
        role: &str,
    ) -> Self {
        let mut node = self.clone();
        if node.kind == DecisionKind::Noul {
            return node;
        }
        if let Some(graph) = &definition.graph {
            for option in &mut node.options {
                if let Some(edge) = graph.edges.iter().find(|edge| {
                    edge.from == role
                        && edge.output.as_ref() == Some(&option.id)
                        && (node.kind == DecisionKind::Choice || edge.id == option.id)
                }) && let Some(target) = definition
                    .roles
                    .iter()
                    .find(|target| target.id.0 == edge.to)
                {
                    option.name.clone_from(&target.name);
                    option.description.clone_from(&target.name);
                }
            }
        }
        node
    }

    pub(crate) fn validate(&self) -> bool {
        let text = |s: &str| !s.trim().is_empty() && s.len() <= 8_192;
        let selector = |s: &str| crate::harness::launch::validate_model(s).is_some();
        if !text(&self.question)
            || self.true_threshold > 10_000
            || self.false_threshold > self.true_threshold
            || self.min_confidence.is_some_and(|v| v > 10_000)
            || self.provider.as_deref().is_some_and(|s| !selector(s))
            || self.model.as_deref().is_some_and(|s| !selector(s))
            || self.kind != DecisionKind::Choice && self.min_confidence.is_some()
        {
            return false;
        }
        if self.kind == DecisionKind::Noul {
            return true;
        }
        let maximum = if self.kind == DecisionKind::Score {
            10
        } else {
            255
        };
        let mut ids = BTreeSet::new();
        (2..=maximum).contains(&self.options.len())
            && self.options.iter().all(|o| {
                text(&o.id)
                    && o.id != "fallback"
                    && text(&o.name)
                    && text(&o.description)
                    && ids.insert(&o.id)
            })
    }

    #[must_use]
    pub fn outputs(&self) -> Vec<(String, String)> {
        if self.kind == DecisionKind::Noul {
            let mut outputs = vec![("yes".into(), "Yes".into()), ("no".into(), "No".into())];
            if self.true_threshold > self.false_threshold {
                outputs.push(("uncertain".into(), "Uncertain".into()));
            }
            return outputs;
        }
        let mut outputs: Vec<_> = self
            .options
            .iter()
            .map(|o| (o.id.clone(), o.name.clone()))
            .collect();
        if self.min_confidence.is_some() {
            outputs.push(("fallback".into(), "Fallback".into()));
        }
        outputs
    }

    pub(crate) fn request(&self, task: &str, incoming: &str) -> Value {
        let answer_space = match self.kind {
            DecisionKind::Choice => {
                json!({"type":"choice", "options": self.options.iter().map(|o| json!({"id":o.id,"description":if o.name == o.description { o.name.clone() } else { format!("{}: {}",o.name,o.description) }})).collect::<Vec<_>>()})
            }
            DecisionKind::Noul => json!({"type":"noul"}),
            DecisionKind::Score => {
                json!({"type":"score","levels": self.options.iter().map(|o| if o.name == o.description { json!(o.name) } else { json!({"label":o.name,"description":o.description}) }).collect::<Vec<_>>()})
            }
        };
        let mut state = Vec::new();
        if self.include_task {
            state.push(json!({"type":"structured","data":{"workflow_task":task}}));
        }
        state.push(json!({"type":"text","text":incoming}));
        json!({"version":1,"state":state,"questions":[{"id":"route","prompt":self.question,"answer_space":answer_space}]})
    }

    /// Validate the complete answer before applying Handshake's explicit routing policy.
    pub(crate) fn route(&self, envelope: &Value) -> Result<String, DecisionResultError> {
        use DecisionResultError::Invalid;
        if !self.validate() || envelope["version"] != 1 || envelope["result"]["kind"] != "turn" {
            return Err(Invalid);
        }
        let outcome = &envelope["result"]["report"]["outcome"];
        if outcome["version"] != 1 {
            return Err(Invalid);
        }
        if outcome["provider"]["provider"]
            .as_str()
            .is_none_or(str::is_empty)
            || outcome["provider"]["model"]
                .as_str()
                .is_none_or(str::is_empty)
        {
            return Err(Invalid);
        }
        let outcomes = outcome["outcomes"]
            .as_array()
            .filter(|a| a.len() == 1)
            .ok_or(Invalid)?;
        let result = &outcomes[0];
        if result["question_id"] != "route" {
            return Err(Invalid);
        }
        if result["status"] == "refused" {
            return Err(DecisionResultError::Refused);
        }
        if result["status"] != "answered" {
            return Err(Invalid);
        }
        let answer = &result["answer"];
        let selected = match self.kind {
            DecisionKind::Choice => {
                if answer["type"] != "choice" {
                    return Err(Invalid);
                }
                let selected = answer["selected"].as_str().ok_or(Invalid)?;
                let distribution = answer["distribution"].as_array().ok_or(Invalid)?;
                let mut ids = BTreeSet::new();
                let mut sum = 0.;
                for entry in distribution {
                    let id = entry["option_id"].as_str().ok_or(Invalid)?;
                    if !self.options.iter().any(|o| o.id == id) || !ids.insert(id) {
                        return Err(Invalid);
                    }
                    sum += probability(&entry["probability"])?;
                }
                if ids.len() != self.options.len()
                    || !ids.contains(selected)
                    || (sum - 1.).abs() > 0.001_001
                {
                    return Err(Invalid);
                }
                selected.to_owned()
            }
            DecisionKind::Noul => {
                if answer["type"] != "noul" {
                    return Err(Invalid);
                }
                let p = probability(&answer["probability"])? * 10_000.;
                if p >= f64::from(self.true_threshold) {
                    "yes"
                } else if p <= f64::from(self.false_threshold) {
                    "no"
                } else {
                    "uncertain"
                }
                .to_owned()
            }
            DecisionKind::Score => self.score_route(answer)?,
        };
        // Confidence is native metadata, never reconstructed from a selected-option probability.
        if let Some(threshold) = self.min_confidence {
            let confidence = result["confidence"]["value"]
                .as_f64()
                .filter(|p| p.is_finite() && (0. ..=1.).contains(p))
                .ok_or(DecisionResultError::ConfidenceUnavailable)?;
            if confidence * 10_000. < f64::from(threshold) {
                return Ok("fallback".into());
            }
        }
        Ok(selected)
    }
    fn score_route(&self, answer: &Value) -> Result<String, DecisionResultError> {
        use DecisionResultError::Invalid;
        if answer["type"] != "score" {
            return Err(Invalid);
        }
        let probabilities = answer["probabilities"]
            .as_array()
            .filter(|p| p.len() == self.options.len())
            .ok_or(Invalid)?;
        let mut sum = 0.;
        let mut expected = 0.;
        for (i, p) in probabilities.iter().enumerate() {
            let p = probability(p)?;
            sum += p;
            expected += f64::from(u16::try_from(i).map_err(|_| Invalid)?) * p;
        }
        let score = answer["value"].as_f64().ok_or(Invalid)?;
        if !score.is_finite()
            || score < 0.
            || score > f64::from(u16::try_from(self.options.len() - 1).map_err(|_| Invalid)?)
            || (sum - 1.).abs() > 0.001_001
            || (score - expected).abs() > 0.001_001
        {
            return Err(Invalid);
        }
        let index = (0..self.options.len() - 1)
            .filter(|i| score >= f64::from(u16::try_from(*i).unwrap_or(0)) + 0.5)
            .count();
        Ok(self.options[index].id.clone())
    }
}

fn probability(value: &Value) -> Result<f64, DecisionResultError> {
    value
        .as_f64()
        .filter(|p| p.is_finite() && (0. ..=1.).contains(p))
        .ok_or(DecisionResultError::Invalid)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(kind: DecisionKind) -> DecisionNode {
        DecisionNode {
            question: "Which route?".into(),
            kind,
            options: (0..3)
                .map(|i| DecisionOption {
                    id: i.to_string(),
                    name: format!("Level {i}"),
                    description: format!("Meaning {i}"),
                })
                .collect(),
            true_threshold: 8000,
            false_threshold: 2000,
            min_confidence: None,
            provider: None,
            model: None,
            include_task: true,
        }
    }
    fn result(answer: &Value) -> Value {
        json!({"version":1,"result":{"kind":"turn","report":{"outcome":{"version":1,"provider":{"provider":"fixture","model":"offline"},"outcomes":[{"question_id":"route","status":"answered","answer":answer}]}}}})
    }
    #[test]
    fn fractional_scores_route_without_replacing_the_answer() {
        let node = node(DecisionKind::Score);
        let report = result(&json!({"type":"score","value":1.43,"probabilities":[0.,0.57,0.43]}));
        assert_eq!(node.route(&report).unwrap(), "1");
        assert_eq!(
            report["result"]["report"]["outcome"]["outcomes"][0]["answer"]["value"],
            1.43
        );
        assert_eq!(
            node.route(&result(
                &json!({"type":"score","value":0.5,"probabilities":[0.5,0.5,0.]})
            ))
            .unwrap(),
            "1"
        );
        assert!(
            node.route(&result(
                &json!({"type":"score","value":1.,"probabilities":[0.,0.57,0.43]})
            ))
            .is_err()
        );
    }
    #[test]
    fn probability_thresholds_have_explicit_boundaries() {
        let mut node = node(DecisionKind::Noul);
        for (p, expected) in [
            (0., "no"),
            (0.2, "no"),
            (0.5, "uncertain"),
            (0.8, "yes"),
            (1., "yes"),
        ] {
            assert_eq!(
                node.route(&result(&json!({"type":"noul","probability":p})))
                    .unwrap(),
                expected
            );
        }
        node.true_threshold = 5000;
        node.false_threshold = 5000;
        assert_eq!(node.outputs().len(), 2);
        assert_eq!(
            node.route(&result(&json!({"type":"noul","probability":0.5})))
                .unwrap(),
            "yes"
        );
        node.false_threshold = 6000;
        assert!(!node.validate());
    }
    #[test]
    fn choice_requires_complete_distribution_and_native_confidence_when_gated() {
        let mut node = node(DecisionKind::Choice);
        let mut report = result(
            &json!({"type":"choice","selected":"0","distribution":[{"option_id":"0","probability":0.8},{"option_id":"1","probability":0.1},{"option_id":"2","probability":0.1}]}),
        );
        assert_eq!(node.route(&report).unwrap(), "0");
        node.min_confidence = Some(6000);
        assert_eq!(
            node.route(&report),
            Err(DecisionResultError::ConfidenceUnavailable)
        );
        report["result"]["report"]["outcome"]["outcomes"][0]["confidence"] = json!({"value":0.4});
        assert_eq!(node.route(&report).unwrap(), "fallback");
        report["result"]["report"]["outcome"]["outcomes"][0]["answer"]["distribution"][1]["option_id"] =
            json!("0");
        assert!(node.route(&report).is_err());
    }
    #[test]
    fn both_report_versions_are_required() {
        let node = node(DecisionKind::Noul);
        let mut report = result(&json!({"type":"noul","probability":0.9}));
        report["result"]["report"]["outcome"]["version"] = json!(2);
        assert_eq!(node.route(&report), Err(DecisionResultError::Invalid));
        report["result"]["report"]["outcome"]
            .as_object_mut()
            .unwrap()
            .remove("version");
        assert_eq!(node.route(&report), Err(DecisionResultError::Invalid));
        report["result"]["report"]["outcome"]["version"] = json!(1);
        report["version"] = json!(2);
        assert_eq!(node.route(&report), Err(DecisionResultError::Invalid));
    }
    #[test]
    fn choice_request_uses_connected_agent_names_without_routing_criteria() {
        let file: toml::Value = toml::from_str(include_str!(
            "../../../examples/workflows/decision-triage.toml"
        ))
        .unwrap();
        let mut definition: crate::WorkflowTypeDefinition =
            file["definition"].clone().try_into().unwrap();
        for option in &mut definition
            .graph
            .as_mut()
            .unwrap()
            .decisions
            .get_mut("classify")
            .unwrap()
            .options
        {
            option.name = "Stale option".into();
            option.description.clear();
        }
        definition
            .roles
            .iter_mut()
            .find(|role| role.id.0 == "scope")
            .unwrap()
            .name = "Plan the work".into();
        crate::validate(&definition).unwrap();
        let node = definition.graph.as_ref().unwrap().decisions["classify"]
            .with_connected_names(&definition, "classify");
        let request = node.request("Incoming task", "Prepared evidence");
        assert_eq!(request["questions"][0]["prompt"], node.question);
        assert_eq!(
            request["questions"][0]["answer_space"]["options"],
            json!([
                {"id":"feature", "description":"Plan the work"},
                {"id":"fix", "description":"Debugger"},
                {"id":"other", "description":"Coordinator"}
            ])
        );
        assert_eq!(
            request["state"][0]["data"]["workflow_task"],
            "Incoming task"
        );
        assert_eq!(request["state"][1]["text"], "Prepared evidence");
    }

    #[test]
    fn connected_score_levels_keep_fractional_results_and_follow_saved_order() {
        let file: toml::Value = toml::from_str(include_str!(
            "../../../examples/workflows/decision-triage.toml"
        ))
        .unwrap();
        let mut definition: crate::WorkflowTypeDefinition =
            file["definition"].clone().try_into().unwrap();
        let graph = definition.graph.as_mut().unwrap();
        let mut node = graph.decisions["scope"].clone();
        node.kind = DecisionKind::Score;
        for edge in graph.edges.iter_mut().filter(|edge| edge.from == "scope") {
            let option = node
                .options
                .iter_mut()
                .find(|option| Some(&option.id) == edge.output.as_ref())
                .unwrap();
            option.id.clone_from(&edge.id);
            option.name.clear();
            option.description.clear();
            edge.output = Some(edge.id.clone());
        }
        graph.decisions.insert("scope".into(), node.clone());
        crate::validate(&definition).unwrap();
        let resolved = node.with_connected_names(&definition, "scope");
        let request = resolved.request("Task", "Evidence");
        assert_eq!(
            request["questions"][0]["answer_space"]["levels"],
            json!(["Implementer", "Planner", "Architect"])
        );
        let answer =
            result(&json!({"type":"score", "value":1.43, "probabilities":[0.0,0.57,0.43]}));
        assert_eq!(resolved.route(&answer).unwrap(), "scope-medium");
        node.options.swap(0, 1);
        let reordered = node.with_connected_names(&definition, "scope");
        assert_eq!(reordered.route(&answer).unwrap(), "scope-small");
        assert_eq!(
            answer["result"]["report"]["outcome"]["outcomes"][0]["answer"]["value"],
            1.43
        );
    }

    #[test]
    fn yes_no_cutoff_routes_the_boundary_to_yes() {
        let mut node = node(DecisionKind::Noul);
        node.true_threshold = 5000;
        node.false_threshold = 5000;
        assert_eq!(node.outputs().len(), 2);
        for (probability, expected) in [(0.49, "no"), (0.5, "yes"), (0.83, "yes")] {
            let answer = result(&json!({"type":"noul", "probability":probability}));
            assert_eq!(node.route(&answer).unwrap(), expected);
            assert_eq!(
                answer["result"]["report"]["outcome"]["outcomes"][0]["answer"]["probability"],
                probability
            );
        }
    }

    #[test]
    fn four_connections_with_two_options_are_rejected() {
        let file: toml::Value = toml::from_str(include_str!(
            "../../../examples/workflows/decision-triage.toml"
        ))
        .unwrap();
        let mut definition: crate::WorkflowTypeDefinition =
            file["definition"].clone().try_into().unwrap();
        let graph = definition.graph.as_mut().unwrap();
        graph
            .decisions
            .get_mut("classify")
            .unwrap()
            .options
            .truncate(2);
        graph.edges.push(crate::GraphEdge {
            id: "fourth-route".into(),
            from: "classify".into(),
            to: "scope".into(),
            event: crate::GraphEvent::Done,
            output: Some("fourth-route".into()),
        });
        let issues = crate::validate(&definition).unwrap_err();
        assert!(issues.iter().any(|issue| {
            issue
                .problem
                .to_string()
                .contains("2 of 4 connections are missing options")
        }));
    }

    #[test]
    fn chained_example_is_a_valid_portable_graph() {
        let file: toml::Value = toml::from_str(include_str!(
            "../../../examples/workflows/decision-triage.toml"
        ))
        .unwrap();
        let definition: crate::WorkflowTypeDefinition =
            file["definition"].clone().try_into().unwrap();
        crate::validate(&definition).unwrap();
        assert_eq!(definition.graph.as_ref().unwrap().decisions.len(), 3);
        let mut blocked = definition;
        blocked
            .graph
            .as_mut()
            .unwrap()
            .receive
            .insert("coordinator".into(), crate::GraphReceive::All);
        assert!(
            crate::validate(&blocked)
                .unwrap_err()
                .iter()
                .any(|issue| issue.problem.to_string().contains("conditional branches"))
        );
    }
}
