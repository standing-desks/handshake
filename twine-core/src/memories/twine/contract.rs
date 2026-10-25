//! AMIS 0.4: pinned schema checks, RFC 8785 integrity and complete local history.
use super::Error;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;
use uuid::Uuid;

const VERSION: &str = "0.4.0";
const FEATURES: [&str; 3] = [
    "amis.scope.v1",
    "amis.revision-graph.v1",
    "amis.integrity.jcs-sha256.v1",
];

pub(super) fn id() -> String {
    Uuid::new_v4().to_string()
}
pub(super) fn now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("RFC3339 supports current time")
}
pub(super) fn hash(bytes: &[u8]) -> String {
    use std::fmt::Write;
    Sha256::digest(bytes)
        .iter()
        .fold(String::with_capacity(64), |mut output, byte| {
            write!(output, "{byte:02x}").expect("String write");
            output
        })
}
pub(super) fn seal(value: &mut Value) -> Result<(), Error> {
    value
        .as_object_mut()
        .ok_or_else(|| Error::Contract("Expected an object".into()))?
        .remove("integrity");
    let bytes = serde_jcs::to_vec(value).map_err(|e| Error::Contract(e.to_string()))?;
    value["integrity"] =
        json!({"algorithm":"sha256","canonicalization":"jcs-rfc8785","digest":hash(&bytes)});
    Ok(())
}
pub(super) fn check_integrity(value: &Value) -> Result<(), Error> {
    let mut actual = value.clone();
    seal(&mut actual)?;
    if value.get("integrity") != actual.get("integrity") {
        return Err(Error::Contract("Canonical integrity mismatch".into()));
    }
    Ok(())
}
fn validator(kind: &str) -> &'static jsonschema::Validator {
    static BUNDLE: OnceLock<jsonschema::Validator> = OnceLock::new();
    static PLAN: OnceLock<jsonschema::Validator> = OnceLock::new();
    static RECEIPT: OnceLock<jsonschema::Validator> = OnceLock::new();
    static CAPABILITIES: OnceLock<jsonschema::Validator> = OnceLock::new();
    let (cell, schema) = match kind {
        "plan" => (
            &PLAN,
            include_str!("../../../contracts/amis-0.4.0/plan.schema.json"),
        ),
        "capabilities" => (
            &CAPABILITIES,
            include_str!("../../../contracts/amis-0.4.0/capabilities.schema.json"),
        ),
        "receipt" => (
            &RECEIPT,
            include_str!("../../../contracts/amis-0.4.0/receipt.schema.json"),
        ),
        _ => (
            &BUNDLE,
            include_str!("../../../contracts/amis-0.4.0/bundle.schema.json"),
        ),
    };
    cell.get_or_init(|| {
        jsonschema::options()
            .should_validate_formats(true)
            .build(&serde_json::from_str(schema).expect("Pinned schema JSON"))
            .expect("Pinned AMIS schema")
    })
}
pub(super) fn validate(kind: &str, value: &Value) -> Result<(), Error> {
    if let Err(error) = validator(kind).validate(value) {
        return Err(Error::Contract(error.to_string()));
    }
    check_integrity(value)
}
pub(super) fn reference(record: &Value) -> Value {
    json!({"memory_id":record["id"],"revision_id":record["revision"]["id"],"digest":record["integrity"]["digest"]})
}
pub(super) fn bundle() -> Result<Value, Error> {
    let mut value = json!({"format":"amis.bundle","version":VERSION,"bundle_id":id(),"exported_at":now(),"producer":{"name":"Twine memories","version":"0.1.0"},"required_features":FEATURES,"history":{"coverage":"complete","missing_parents":[]},"records":[],"snapshots":[],"extensions":{}});
    seal(&mut value)?;
    Ok(value)
}
pub(super) fn snapshot(bundle: &mut Value, text: &str) -> String {
    let digest = hash(text.as_bytes());
    let snapshots = bundle["snapshots"]
        .as_array_mut()
        .expect("Bundle snapshots");
    if !snapshots.iter().any(|s| s["sha256"] == digest) {
        snapshots.push(json!({"sha256":digest,"byte_length":text.len(),"media_type":"text/markdown","availability":"included","text":text}));
    }
    digest
}
#[allow(clippy::too_many_arguments)]
pub(super) fn record(
    memory: &str,
    parent: Option<&Value>,
    title: &str,
    text: &str,
    project: &str,
    sources: &Value,
    inputs: &[Value],
    mode: &str,
) -> Result<Value, Error> {
    let timestamp = now();
    let mut record = json!({"format":"amis.record","version":VERSION,"id":memory,"revision":{"id":id(),"parents":parent.map(reference).into_iter().collect::<Vec<_>>(),"created_at":timestamp},"created_at":parent.map_or_else(||json!(timestamp),|p|p["created_at"].clone()),"title":title,"kind":"project","body":{"format":"text/markdown","text":text},"scope":{"kind":"project","project_ref":project},"status":"active","validity":{"not_before":null,"expires_at":null},"sources":sources,"provenance":{"completeness":"complete","omissions":[]},"derivation":{"mode":mode,"adapter":"com.twine.memories@0.1.0","inputs":inputs},"extensions":{}});
    seal(&mut record)?;
    Ok(record)
}
pub(super) fn append(bundle: &mut Value, record: Value) {
    bundle["records"]
        .as_array_mut()
        .expect("Bundle records")
        .push(record);
}
pub(super) fn find<'a>(bundle: &'a Value, revision: &str) -> Option<&'a Value> {
    bundle["records"]
        .as_array()?
        .iter()
        .find(|r| r["revision"]["id"] == revision)
}
pub(super) fn validate_bundle(bundle: &Value, project: &str) -> Result<(), Error> {
    validate("bundle", bundle)?;
    if bundle["version"] != VERSION || bundle["history"]["coverage"] != "complete" {
        return Err(Error::Contract(
            "Unsupported version or incomplete history".into(),
        ));
    }
    for feature in bundle["required_features"].as_array().into_iter().flatten() {
        if !FEATURES.iter().any(|known| feature == known) {
            return Err(Error::Contract("Unsupported required AMIS feature".into()));
        }
    }
    let mut revisions = HashMap::new();
    let mut snapshot_hashes = HashSet::new();
    for snapshot in bundle["snapshots"].as_array().into_iter().flatten() {
        let text = snapshot["text"]
            .as_str()
            .ok_or_else(|| Error::Contract("Missing included snapshot".into()))?;
        let digest = hash(text.as_bytes());
        if snapshot["sha256"] != digest
            || snapshot["byte_length"].as_u64() != Some(text.len() as u64)
            || !snapshot_hashes.insert(digest)
        {
            return Err(Error::Contract(
                "Invalid or duplicate snapshot bytes".into(),
            ));
        }
    }
    for record in bundle["records"].as_array().into_iter().flatten() {
        check_integrity(record)?;
        if record["scope"]["kind"] != "project" || record["scope"]["project_ref"] != project {
            return Err(Error::Contract("Project binding mismatch".into()));
        }
        let revision = record["revision"]["id"]
            .as_str()
            .ok_or_else(|| Error::Contract("Missing revision ID".into()))?;
        if revisions.insert(revision, record).is_some() {
            return Err(Error::Contract("Duplicate revision ID".into()));
        }
        for source in record["sources"].as_array().into_iter().flatten() {
            if !snapshot_hashes.contains(source["snapshot_ref"].as_str().unwrap_or_default()) {
                return Err(Error::Contract("Missing source snapshot".into()));
            }
        }
        for parent in record["revision"]["parents"]
            .as_array()
            .into_iter()
            .flatten()
        {
            if parent["memory_id"] != record["id"] {
                return Err(Error::Contract(
                    "Revision parent changes memory identity".into(),
                ));
            }
        }
        for link in record["revision"]["parents"]
            .as_array()
            .into_iter()
            .flatten()
            .chain(
                record["derivation"]["inputs"]
                    .as_array()
                    .into_iter()
                    .flatten(),
            )
        {
            let base = revisions
                .get(link["revision_id"].as_str().unwrap_or_default())
                .ok_or_else(|| Error::Contract("History must be ordered and complete".into()))?;
            if reference(base) != *link || base["revision"]["id"] == revision {
                return Err(Error::Contract("Invalid ancestry reference".into()));
            }
        }
    }
    Ok(())
}

/// Reject duplicate JSON object keys before integrity validation can lose evidence.
pub(super) fn parse(bytes: &[u8]) -> Result<Value, Error> {
    struct Strict(Value);
    impl<'de> serde::Deserialize<'de> for Strict {
        fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            struct Visitor;
            impl<'de> serde::de::Visitor<'de> for Visitor {
                type Value = Strict;
                fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                    formatter.write_str("JSON without duplicate keys")
                }
                fn visit_map<A: serde::de::MapAccess<'de>>(
                    self,
                    mut map: A,
                ) -> Result<Strict, A::Error> {
                    let mut output = serde_json::Map::new();
                    while let Some(key) = map.next_key::<String>()? {
                        if output.contains_key(&key) {
                            return Err(serde::de::Error::custom("Duplicate JSON key"));
                        }
                        output.insert(key, map.next_value::<Strict>()?.0);
                    }
                    Ok(Strict(Value::Object(output)))
                }
                fn visit_seq<A: serde::de::SeqAccess<'de>>(
                    self,
                    mut seq: A,
                ) -> Result<Strict, A::Error> {
                    let mut output = Vec::new();
                    while let Some(value) = seq.next_element::<Strict>()? {
                        output.push(value.0);
                    }
                    Ok(Strict(Value::Array(output)))
                }
                fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Strict, E> {
                    Ok(Strict(json!(v)))
                }
                fn visit_unit<E: serde::de::Error>(self) -> Result<Strict, E> {
                    Ok(Strict(Value::Null))
                }
            }
            deserializer.deserialize_any(Visitor)
        }
    }
    Ok(serde_json::from_slice::<Strict>(bytes)?.0)
}
pub(super) fn configuration(project: &str, provider: &str) -> String {
    hash(
        format!(
            "amis-0.4.0:9723ef4:com.twine.project-auto.v1:{project}:{provider}:native-profile-v1"
        )
        .as_bytes(),
    )
}
pub(super) fn capabilities(provider: &str, configuration: &str) -> Result<Value, Error> {
    let mut value = json!({"format":"amis.capabilities","version":VERSION,"provider":provider,
        "implementation":{"name":"Twine native project memory","version":"0.1.0"},"protocol_versions":[VERSION],"features":FEATURES,
        "profiles":[{"id":format!("com.twine.{provider}.project-native.v1"),"version":"1","operations":["describe","scan","normalize","plan","apply","verify"],"scopes":["project"],"kinds":["project"],"coordination":["cooperative_lock"],"verification":["native-bytes"]}],
        "limits":{"max_document_bytes":9_007_199_254_740_991_u64,"max_records":9_007_199_254_740_991_u64,"max_depth":128,"max_source_bytes":9_007_199_254_740_991_u64,"max_total_source_bytes":9_007_199_254_740_991_u64},
        "configuration_digest":configuration,"observed_at":now(),"expires_at":expiry()});
    seal(&mut value)?;
    validate("capabilities", &value)?;
    Ok(value)
}
pub(super) fn expiry() -> String {
    (time::OffsetDateTime::now_utc() + time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)
        .expect("RFC3339")
}
pub(super) fn expired(value: &Value) -> bool {
    value
        .as_str()
        .and_then(|s| {
            time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339).ok()
        })
        .is_none_or(|date| date <= time::OffsetDateTime::now_utc())
}
pub(super) fn heads(bundle: &Value, id: &str) -> Vec<Value> {
    let records: Vec<_> = bundle["records"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["id"] == id)
        .collect();
    let parents: HashSet<_> = records
        .iter()
        .flat_map(|r| r["revision"]["parents"].as_array().into_iter().flatten())
        .filter_map(|p| p["revision_id"].as_str())
        .collect();
    records
        .into_iter()
        .filter(|r| !parents.contains(r["revision"]["id"].as_str().unwrap_or_default()))
        .map(reference)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_json_keys_are_rejected_before_hashing() {
        assert!(parse(br#"{"scope":{"kind":"project","kind":"global"}}"#).is_err());
    }
    #[test]
    fn parent_cannot_cross_memory_identity() {
        let project = id();
        let mut bundle = bundle().unwrap();
        let snapshot = snapshot(&mut bundle, "Fact.");
        let a=record(&id(),None,"Fact","Fact.",&project,&json!([{"source_id":"a","provider":"codex","locator":"a","snapshot_ref":snapshot,"observed_at":now(),"source_created_at":null,"native_kind":"project"}]),&[],"verbatim").unwrap();
        let b = record(
            &id(),
            Some(&a),
            "Fact",
            "Fact.",
            &project,
            &a["sources"],
            &[],
            "verbatim",
        )
        .unwrap();
        append(&mut bundle, a);
        append(&mut bundle, b);
        seal(&mut bundle).unwrap();
        assert!(validate_bundle(&bundle, &project).is_err());
    }
}
