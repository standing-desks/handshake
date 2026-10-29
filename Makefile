.DEFAULT_GOAL := help
# Xcode consumes one selected local binary package. Serialize stages that select its profile.
.NOTPARALLEL:

OUT := $(CURDIR)/out
PROJECT := macOS/Handshake/Handshake.xcodeproj
LIB_TARGET := aarch64-apple-darwin
export CARGO_TARGET_DIR := $(CURDIR)/target
export MACOSX_DEPLOYMENT_TARGET := 26.0
export SWIFT_PACKAGES_DIR := $(OUT)/dependencies/SourcePackages
XCODEBUILD := TMPDIR="$(OUT)/dependencies/tmp" xcodebuild -project $(PROJECT) -scheme Handshake -skipPackagePluginValidation \
	-clonedSourcePackagesDirPath "$(SWIFT_PACKAGES_DIR)" \
	-packageCachePath "$(OUT)/dependencies/cache" -onlyUsePackageVersionsFromResolvedFile
XCODEBUILD_DEBUG := $(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=arm64'
XCODEBUILD_RELEASE := $(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS'
RELEASE_SETTINGS := ARCHS=arm64 GCC_GENERATE_DEBUGGING_SYMBOLS=NO DEBUG_INFORMATION_FORMAT= \
	ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
XCODE_BUILD_ARGS ?=
FRAMEWORK_BUILD := sh macOS/HandshakeCorePackage/build.sh
FRAMEWORK_SELECT := sh macOS/HandshakeCorePackage/select.sh
TESTS_DIR := $(OUT)/tests/build
# Tests run from these build products without the project, so CI can build once and test on other machines.
TEST_PRODUCTS := $(TESTS_DIR)/Build/Products
TEST_ARCHIVE := $(OUT)/tests/products.tar.gz
TEST_RUN = xcodebuild test-without-building -xctestrun "$(TEST_PRODUCTS)"/*.xctestrun \
	-destination 'platform=macOS,arch=arm64' -derivedDataPath "$(TESTS_DIR)"
SITE_DIR := $(OUT)/docs/site
LIB_DOC_DIR := $(OUT)/docs/rust
APP_DOC_DIR := $(OUT)/docs/swift
DMG_TOOLS_DIR := $(OUT)/packaging/tools
ACTIONLINT ?= actionlint
# The test host uses fresh temporary data; Xcode products and results stay in out/tests.
TEST_ENV := TEST_RUNNER_HANDSHAKE_PREFERENCES_SUITE=com.twineproject.Twine.tests.unit-host \
	TEST_RUNNER_DEVELOPER_DIR="$${DEVELOPER_DIR:-$$(xcode-select -p)}" \
	TEST_RUNNER_PATH="$$(dirname "$$(xcrun --find git)"):$$PATH"

# PREBUILT=1 runs a target without its prerequisites. CI uses it to run tests from unpacked test products.
needs = $(if $(PREBUILT),,$(1))

# Tests outside this list are retired from default runs, but remain available with ONLY or ALL=1.
# Add a test here to re-enable it in local and CI default runs.
UI_DEFAULT_TESTS := testFirstLaunchShowsStartPage \
	testBrowserCLIControlsNativePageAndUserCanTakeOver \
	testBrowserCLINestedDocumentsAndRichInteractions \
	testBrowserControlFlagGatesAgentInstructionsAndRevokesLiveCommands \
	testBrowserControlFlagGatesClaudeMCPAndRevokesLiveCommands \
	testKeepAwakeSharesWindowsStopsOnQuitAndRelaunchesOff \
	testKeepAwakeRecoversChildFailureAndReleasesAfterForceQuit \
	testBrowserTabsShareRenamePinMoveReopenAndRestore \
	testBrowserZoomRetainsPageAndKeepsCornerLinksInteractive \
	testBrowserNavigationValidationPopupAndContextualClose \
	testPDFImageAndVideoPreviewsShareFileTabControls \
	testManagedTabsKeepCreateButtonBesideTabsAndReachableDuringOverflow \
	testTabCreationButtonsMatchTabsAcrossAppearancesAndZoom \
	testManagedTabsValidateCancelAndResetNamesAndHandleEmptySearch \
	testManagedTabsHideTopLevelRunningAndExitIndicators \
	testManagedFileTabsDisambiguateSearchPinAndReopen \
	testTabManagementIsStandardAndIgnoresRetiredSettings \
	testTabSwitcherSupportsKeyboardSelection \
	testManagedTabsRenameReorderPinNavigateAndReopenWithoutRestarting \
	testManagedTabsKeepSplitNeighborAndRestoreFilesAfterQuit \
	testManagedTabsConfirmBeforeStoppingARunningAgent \
	testExperimentalFeatureControlsMemorySharingImmediatelyAndPersists \
	testExperimentalSettingsMigrateLegacyImportsOnceAndPreserveOptIn \
	testMemoryHeaderSharingControlsRemainIndependentAndPersist \
	testMemoryHeaderOpensSettingsWhenPolicySaveFails \
	testHandshakeMemoriesRemainUsableAtMaximumZoom \
	testSidebarDefaultsClosedAndRemembersVisibilityAfterRelaunch \
	testGitFileTreeShowsPrimaryCheckoutChangesAcrossRepositories \
	testGitFileTreeRefreshesConflictsAndUnavailableRepositories \
	testFileMenuCanOpenWindowsAndFoldersAfterClosingLastWindow \
	testSettingsPopupLoadsSavesAndProtectsUnsavedChanges \
	testSavingSettingsReflowsExistingTerminalsInAllFolderWindows \
	testSidebarToolbarInFullScreenInDarkAppearance \
	testZoomIsSharedByNewWindowsAndRememberedAfterRelaunch \
	testZoomReflowsTerminalAndScalesEditorPopoverAndSheet \
	testZoomBoundsKeepSplitDraggingAndSmallWindowsUsable \
	testZoomedWebPreviewsKeepLocalLinksInteractive \
	testHTMLPreviewFillsViewportAtEveryZoomLevel \
	testRelaunchOpensLastFolderAndReturnsToStartPage \
	testFolderWindowsKeepShellsAndCommandsIndependent \
	testOpeningAnOpenFolderFocusesItsWindowIncludingSymlinks \
	testRelaunchRestoresAllFolderWindowsAndLeavesClosedFoldersClosed \
	testClosingAnUnavailableRestoredFolderKeepsItClosedOnRelaunch \
	testSessionsOwnTabsAndRestoreFreshShellsAfterRelaunch \
	testSidebarTabsNestUnderSessionsMoveWithUndoAndSwitchLayouts \
	testMinimizedSidebarRailPeeksAndDocks \
	testQuitStopsShellAndDescendant \
	testTerminalRunsLibraryInjectionAndDebugger \
	testTerminalRenderingRemainsUsableAcrossZoomAndResize \
	testShellAgentPresentationPreservesShellAndReturnsAfterExit \
	testWorkflowTraceUsesPromptInsteadOfGraphAndSurvivesRelaunch \
	testSingleAgentStartsInteractivelyTakesInputAndCancels \
	testSingleAgentUsesHarnessDefaultsAndRemembersYoloMode \
	testKiroLaunchesRecordsTracesAndResumesEachConversation \
	testClaudeMinimapDotsSelectTheirTraceAndScrollToThePrompt \
	testTimelineInspectorShowsNestedCallsFiltersAndSurvivesRelaunch \
	testNativeHistoryShowsModelSummaryFullDetailsAndStoragePinAfterRelaunch \
	testTraceViewModesPreserveSelectionAndCollapsedState \
	testLegacyTraceEventsKeepLoadedPagesWhenThePanelRefreshes \
	testAgentReceivesTerminalColors \
	testForceQuitPreservesAgentOutputAndCanResumeItsSession \
	testAdversarialHarnessSelectionUserCompletionReviewLoopAndTraces \
	testWorkflowDesignerKeyboardEntryValidationAndBuiltinCopy \
	testDecisionNodesSwitchFromAgentsAndRouteThroughSharedDragConnectors \
	testDecisionValidationReturnsToAnOffscreenNodeRepeatedly \
	testAlwaysDecisionOutputsAndZoomButtonHitAreas \
	testSavedWorkflowHoverDeleteRequiresConfirmation \
	testBentoPanesKeepEachShellAndMoveTheKeyboardBetweenThem \
	testTerminalSplitsResizeKeepTheirNeighborAndRestoreOutput \
	testFileEditingUndoSaveAndConflictChoices \
	testAutosaveSettingsApplyToOpenTabsAndCommandSSavesExplicitly \
	testFileTreeContextMenusTargetClickedRowsAndPreserveEdits \
	testSwiftSyntaxHighlightingPreservesUnicodeCRLFEditingAndUndo \
	testSyntaxLanguageOverridesStayWithTheirFileTabs \
	testHTMLSyntaxHighlightingPreservesSourceEditingAndCSSDetection \
	testMarkdownPreviewSourceSaveReloadAndLocalLinks \
	testMemoryDockReadRefreshAndLeaveSourcesUnchanged \
	testHandshakeMemoriesAutomaticallyShareBothDirectionsAndSurviveRelaunch \
	testHandshakeMemoriesPublishNewFilesWhileBothProfilesAreActive \
	testRunningAgentRefreshesSharedMemoryAtNextPromptWithoutRestart \
	testMemoryCorrectionReachesRunningAgentUnderPressureAndSurvivesRelaunch \
	testMemoryCorrectionPreservesDraftWhenSelectedMemoryChanges \
	testMemoryDockClaudeScopesNarrowNavigationAndHiddenTerminal \
	testMemoryDockOtherWorkspacesRememberNavigationAcrossRelaunch \
	testMemoryDockArrowNavigationKeepsFocusAfterRendering \
	testCodexMemoryMarkdownRenderingLinksEditingAndConflict \
	testClaudeMemoryMarkdownRenderingLinksEditingAndConflict \
	testSQLiteMemoryMarkdownRendersWithoutAnEditAction \
	testClearedTraceOpensSavedInputAndOutputWithoutAScrollbackWarning
UI_VISUAL_TESTS := testFolderWindowInDarkAppearance \
	testDraftAndFooterAtMinimumWindowSizeInDarkAppearance \
	testTracesInDarkAppearance testCoordinatorGraphInDarkAppearance \
	testShortOutputMinimapInBothAppearances
# SHARD=n/N runs every Nth default test, starting at the nth, so CI can split the list across machines.
UI_SHARD_TESTS = $(shell printf '%s\n' $(UI_DEFAULT_TESTS) | \
	awk -v shard='$(SHARD)' 'BEGIN { split(shard, part, "/") } part[2] > 0 && NR % part[2] == part[1] % part[2]')
# RETRIES=n reruns each failed UI test up to n more times. CI uses RETRIES=1.
UI_RETRY_ARGS = $(if $(filter-out 0,$(RETRIES)),-retry-tests-on-failure -test-iterations $(shell expr $(RETRIES) + 1))
UI_TEST_ARGS := $(if $(strip $(ONLY)),\
	$(addprefix -only-testing:HandshakeUITests/HandshakeUITests/,$(ONLY)),\
	$(if $(filter 1,$(ALL)),-only-testing:HandshakeUITests,\
		$(addprefix -only-testing:HandshakeUITests/HandshakeUITests/,\
			$(if $(strip $(SHARD)),$(UI_SHARD_TESTS),$(UI_DEFAULT_TESTS)))))

.PHONY: help
help: ## Show this help
	@echo 'usage: make <target> [VARIABLE=value ...]'
	@awk -F ':.*## ' '/^##@ /{printf "\n%s\n", substr($$0, 5)} /^[a-z-]+:.*## /{printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Build
.PHONY: debug
debug: $(call needs,deps-debug) ## Build the debug app
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(OUT)/debug" build $(XCODE_BUILD_ARGS)

.PHONY: release
release: $(call needs,deps-release) ## Build the release app
	$(XCODEBUILD_RELEASE) -derivedDataPath "$(OUT)/release" build $(RELEASE_SETTINGS) $(XCODE_BUILD_ARGS)

.PHONY: clean
clean: clean-dev-state ## Remove all build output and development data
	cargo clean
	rm -rf "$(OUT)"

.PHONY: clean-dev-state
clean-dev-state: ## Remove development data only
	sh scripts/clean-dev-state.sh

##@ Format, lint and test
.PHONY: fmt
fmt: fmt-lib fmt-app ## Format the library and the app

.PHONY: lint
lint: lint-lib lint-app ## Lint the library and the app

.PHONY: test
test: test-lib test-app ## Test the library and the app

.PHONY: check
check: check-lib check-app ## Lint and test the library and the app

.PHONY: fmt-lib
fmt-lib: ## Format the library
	cargo fmt --all

.PHONY: lint-lib
lint-lib: ## Lint the library
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings

.PHONY: test-lib
test-lib: ## Test the library (LIB_TEST_ARGS='filter -- flags')
	@set -eu; \
	handshake_config_tests=$$(mktemp -d "$${TMPDIR:-/tmp}/handshake-config-tests.XXXXXX"); \
	trap 'rm -rf "$$handshake_config_tests"' EXIT; \
	env -u HANDSHAKE_CONFIG_PATH -u TWINE_CONFIG_PATH XDG_CONFIG_HOME="$$handshake_config_tests" \
		KIRO_HOME="$$handshake_config_tests/kiro" \
		cargo test --workspace --locked $(LIB_TEST_ARGS)

.PHONY: check-lib
check-lib: lint-lib test-lib ## Lint and test the library

.PHONY: fmt-app
fmt-app: ## Format the app
	swift format --in-place --recursive macOS/

.PHONY: lint-app
lint-app: $(call needs,deps-debug) ## Lint the app
	swift format lint --strict --recursive macOS/
	macOS/Handshake/Scripts/swiftlint.sh

.PHONY: test-app
test-app: $(call needs,build-tests) ## Run the app's unit tests
	@set -eu; \
	handshake_test_data=$$(mktemp -d "$${TMPDIR:-/tmp}/handshake-unit-tests.XXXXXX"); \
	trap 'rm -rf "$$handshake_test_data"' EXIT; \
	mkdir -p "$$handshake_test_data/config/handshake" "$$handshake_test_data/native/codex" "$$handshake_test_data/native/claude"; \
	printf '[experimental]\ncross_agent_memory_consolidation = true\n' > "$$handshake_test_data/config/handshake/config.toml"; \
	TEST_RUNNER_CODEX_HOME="$$handshake_test_data/native/codex" \
	TEST_RUNNER_CLAUDE_CONFIG_DIR="$$handshake_test_data/native/claude" \
	TEST_RUNNER_HANDSHAKE_DATA_DIRECTORY="$$handshake_test_data" \
	TEST_RUNNER_XDG_CONFIG_HOME="$$handshake_test_data/config" $(TEST_ENV) \
		$(TEST_RUN) -only-testing:HandshakeTests

.PHONY: check-app
check-app: lint-app test-app ## Lint and unit-test the app

.PHONY: ui-test
ui-test: $(call needs,build-tests) ## Run UI tests (ONLY="testA testB", ALL=1 or SHARD=n/N; RETRIES=n)
	@test -n "$(strip $(UI_TEST_ARGS))" || { echo 'usage: make ui-test [ONLY="testA testB" | ALL=1 | SHARD=n/N]' >&2; exit 2; }
	TEST_RUNNER_HANDSHAKE_TEST_GIT="$$(xcrun --find git)" $(TEST_ENV) $(TEST_RUN) $(UI_TEST_ARGS) $(UI_RETRY_ARGS)

.PHONY: ui-test-visual
ui-test-visual: ## Run the visual UI tests
	$(MAKE) ui-test ONLY="$(UI_VISUAL_TESTS)"

.PHONY: lint-ci
lint-ci: check-assets ## Lint CI workflows and build scripts
	$(ACTIONLINT) -ignore 'label "xcode-27" is unknown'
	shellcheck scripts/*.sh macOS/HandshakeCorePackage/*.sh macOS/Handshake/Scripts/*.sh

.PHONY: check-bundle
check-bundle: ## Test and lint the release scripts
	bash .github/release/test-notes.sh
	bash .github/release/test-signing.sh
	shellcheck .github/release/*.sh

# Build stages. debug, release and the app targets run these first.
.PHONY: framework-debug
framework-debug:
	cargo build --package handshake-cli --package handshake-bridge --profile debug --locked --target $(LIB_TARGET)
	$(FRAMEWORK_BUILD) debug

.PHONY: framework-release
framework-release:
	cargo build --package handshake-cli --package handshake-bridge --profile release --locked --target $(LIB_TARGET)
	$(FRAMEWORK_BUILD) release

.PHONY: deps-debug
deps-debug: $(call needs,framework-debug)
	mkdir -p "$(OUT)/dependencies/tmp"
	$(FRAMEWORK_SELECT) debug
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(OUT)/debug" -resolvePackageDependencies
	sh macOS/Handshake/Scripts/prepare-swiftterm.sh "$(SWIFT_PACKAGES_DIR)/checkouts/SwiftTerm"

.PHONY: deps-release
deps-release: $(call needs,framework-release)
	mkdir -p "$(OUT)/dependencies/tmp"
	$(FRAMEWORK_SELECT) release
	$(XCODEBUILD_RELEASE) -derivedDataPath "$(OUT)/release" -resolvePackageDependencies
	sh macOS/Handshake/Scripts/prepare-swiftterm.sh "$(SWIFT_PACKAGES_DIR)/checkouts/SwiftTerm"

.PHONY: build-tests
build-tests: $(call needs,deps-debug)
	rm -f "$(TEST_PRODUCTS)"/*.xctestrun
	$(XCODEBUILD_DEBUG) build-for-testing -derivedDataPath "$(TESTS_DIR)" $(XCODE_BUILD_ARGS)

# CI archives the test products in the build job and unpacks them in each test job.
.PHONY: pack-tests
pack-tests: $(call needs,build-tests)
	cd "$(TEST_PRODUCTS)" && tar -czf "$(TEST_ARCHIVE)" Debug/Handshake.app Debug/HandshakeUITests-Runner.app *.xctestrun

.PHONY: unpack-tests
unpack-tests:
	mkdir -p "$(TEST_PRODUCTS)"
	tar -xzf "$(TEST_ARCHIVE)" -C "$(TEST_PRODUCTS)"

##@ DMG packaging
.PHONY: build-dmg
build-dmg: dmg-tools ## Create a DMG from a signed app (APP=path DMG=path)
	@test -n "$(APP)" && test -n "$(DMG)" || { echo 'usage: make build-dmg APP=path DMG=path' >&2; exit 2; }
	bash .github/release/build-dmg.sh "$(APP)" "$(DMG)"

.PHONY: validate-dmg
validate-dmg: dmg-tools ## Validate an existing DMG (DMG=path [VERSION=x.y.z])
	@test -n "$(DMG)" || { echo 'usage: make validate-dmg DMG=path [VERSION=x.y.z]' >&2; exit 2; }
	bash .github/release/validate-dmg.sh "$(DMG)" "$(VERSION)"

.PHONY: dmg-tools
dmg-tools: $(DMG_TOOLS_DIR)/.installed ## Install the DMG tools

$(DMG_TOOLS_DIR)/.installed: .github/release/dmg-requirements.txt
	python3 -m venv "$(DMG_TOOLS_DIR)"
	"$(DMG_TOOLS_DIR)/bin/python3" -m pip install --disable-pip-version-check --cache-dir "$(OUT)/dependencies/pip" -r $<
	touch "$@"

.PHONY: regenerate-dmg-artwork
regenerate-dmg-artwork: ## Regenerate the DMG background
	swift format --in-place .github/release/render-background.swift
	swift .github/release/render-background.swift

##@ Documentation
.PHONY: build-site
build-site: check-site $(call needs,docs-lib docs-app) ## Build the documentation website
	rm -rf "$(SITE_DIR)"
	cd site && npm ci && npm run build -- --outDir "$(SITE_DIR)" --emptyOutDir
	cp -R "$(LIB_DOC_DIR)/doc/." "$(SITE_DIR)/documentation/rust/"
	cp -R "$(APP_DOC_DIR)/Build/Products/Debug/Handshake.doccarchive" "$(SITE_DIR)/documentation/swift"

.PHONY: docs-lib
docs-lib: ## Build the library API reference
	RUSTDOCFLAGS='-D warnings' cargo doc --workspace --no-deps --locked
	mkdir -p "$(LIB_DOC_DIR)"
	rm -rf "$(LIB_DOC_DIR)/doc"
	cp -R "$(CURDIR)/target/doc" "$(LIB_DOC_DIR)/doc"

.PHONY: docs-app
docs-app: $(call needs,deps-debug) ## Build the app API reference
	$(XCODEBUILD_DEBUG) docbuild -derivedDataPath "$(APP_DOC_DIR)" \
		OTHER_SWIFT_FLAGS='-symbol-graph-skip-synthesized-members' \
		DOCC_HOSTING_BASE_PATH=handshake/documentation/swift DOCC_TRANSFORM_FOR_STATIC_HOSTING=YES $(XCODE_BUILD_ARGS)
	# Validate Handshake's catalog strictly without treating dependency documentation warnings as errors.
	mkdir -p "$(APP_DOC_DIR)/Build/Products/Debug"
	xcrun docc convert macOS/Handshake/Handshake/Documentation.docc \
		--additional-symbol-graph-dir "$(APP_DOC_DIR)/Build/Intermediates.noindex/Handshake.build/Debug/Handshake.build/symbol-graph" \
		--output-dir "$(APP_DOC_DIR)/Build/Products/Debug/Handshake.doccarchive" \
		--fallback-display-name Handshake --fallback-bundle-identifier com.twineproject.Twine \
		--fallback-default-module-kind Application --hosting-base-path handshake/documentation/swift \
		--transform-for-static-hosting --warnings-as-errors \
		--source-service github --source-service-base-url https://github.com/standing-desks/handshake/blob/main \
		--checkout-path "$(CURDIR)"

.PHONY: check-site
check-site: check-assets ## Check website downloads, copy controls, and screenshots without desktop access
	node site/scripts/test-site.cjs

.PHONY: serve-site
serve-site: ## Serve the website locally with live reload
	cd site && npm ci && npm run dev

.PHONY: check-assets sync-assets
check-assets: ## Verify shared brand sources and component copies
	node assets/sync.cjs

sync-assets: ## Refresh component copies and the generated README lockup
	node assets/sync.cjs --write

.PHONY: cli
cli: ## Build the browser CLI
	cargo build --package handshake-cli --locked
