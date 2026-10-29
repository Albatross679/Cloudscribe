#!/usr/bin/env python3
"""Fresh pinned-source and idempotent patch regression. No app is launched."""
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("patch_osw", ROOT / "scripts/patch_osw.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
checkout = ROOT
if not (checkout / ".git").exists():
    raise SystemExit("Run this test in the fork checkout.")
archive = subprocess.check_output(["git", "-C", str(checkout), "archive", patcher.UPSTREAM_REF, "OpenSuperWhisper"])

with tempfile.TemporaryDirectory(prefix="osw-patch-tests-") as directory:
    root = Path(directory)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for member in source.getmembers():
            if not member.isfile():
                continue
            path = root / member.name
            if not path.resolve().is_relative_to(root.resolve()):
                raise AssertionError("unexpected archive path")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(source.extractfile(member).read())
    patcher.APP = root / "OpenSuperWhisper"
    steps = [
        patcher.add_engine_file, patcher.patch_preferences, patcher.patch_service,
        patcher.patch_settings, patcher.patch_combined_engine_selection,
        patcher.patch_local_credentials, patcher.patch_shortcut_behavior,
        patcher.patch_cloudflare_setup, patcher.patch_menu_bar,
        patcher.patch_onboarding, patcher.patch_language_util,
        patcher.patch_fluidaudio_engine, patcher.patch_transcription_settings,
        patcher.patch_failure_paths, patcher.patch_content_view, patcher.patch_usage_metrics,
        patcher.patch_openrouter_prices, patcher.patch_local_engine_tab,
        patcher.patch_dictation_deadline, patcher.patch_service_concurrency_warnings,
        patcher.patch_theme, patcher.patch_transcribing_timer,
    ]
    def snapshot():
        return {str(p.relative_to(patcher.APP)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in patcher.APP.rglob("*.swift")}
    for step in steps:
        step()
    first = snapshot()
    tracked = {str(p.relative_to(ROOT / 'OpenSuperWhisper')): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in (ROOT / 'OpenSuperWhisper').rglob('*.swift')}
    assert first == tracked, 'tracked fork app differs from fresh pinned-source generation'
    assert patcher.CHECKOUT == ROOT, 'patcher must operate in the fork root'
    assert not (ROOT / 'repos/OpenSuperWhisper').exists(), 'nested app source is forbidden'
    for step in steps:
        step()
    assert snapshot() == first, "patch rerun changed generated source"
    settings = (patcher.APP / "Settings.swift").read_text()
    assert 'Picker("Engine",' not in settings, "SwiftUI's segmented engine bar acts on focus clicks"
    assert 'Picker("Provider",' not in settings
    assert settings.count('EngineChoiceSelector(') == 1
    assert settings.count('selection: $viewModel.engineSelection,') == 1
    assert 'if viewModel.selectedEngine == "cloudflare" && !viewModel.showsLocalEngines {' in settings
    selector = (patcher.APP / "Engines/EngineChoiceSelector.swift").read_text()
    for required in ['override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }',
                     'EngineTab.allCases', 'accessibilityLabel: "Engine"', '.frame(maxWidth: .infinity)']:
        assert required in selector, f"missing engine selector contract: {required}"
    assert 'activeEngine.menuBarTitle' in (patcher.APP / "OpenSuperWhisperApp.swift").read_text()
    assert 'credentialStorageMessage' in settings
    assert 'isRefreshingCloudCredentials' in settings
    assert 'it stays in this Mac\'s Keychain' not in settings
    assert (patcher.APP / "Utils/LocalCredentialStore.swift").exists()
    service = (patcher.APP / "TranscriptionService.swift").read_text()
    assert service.count('UsageTracking.$context.withValue') == 1
    assert service.count('let usageEngine = currentEngine') == 1
    assert 'let seconds = await UsageTracking.audioSeconds(url)' in service
    assert 'guard let engine = usageEngine else' in service
    assert 'let store = usageMetricsStore' in service
    assert 'metricOutcome = "cancelled"' in service
    assert service.count('static let dictationDeadline: Duration = .seconds(8)') == 1
    indicator = (patcher.APP / "Indicator/IndicatorWindow.swift").read_text()
    assert 'let deadline = ContinuousClock.now + TranscriptionService.dictationDeadline' in indicator
    assert 'metricID: metricID, deadline: deadline)' in indicator
    assert indicator.count('startTranscribingClock(deadline: deadline)') == 1
    assert 'showAutoDismissingMessage(.timedOut)' in indicator
    assert (patcher.APP / 'Indicator/TranscribingClock.swift').read_bytes() == (ROOT / 'src/client/TranscribingClock.swift').read_bytes()
    # Manual transcription keeps the per-request timeouts.
    for name in ("ContentView.swift", "TranscriptionQueue.swift"):
        assert 'deadline:' not in (patcher.APP / name).read_text(), f"{name} must not pass the dictation deadline"
    for name in ("ContentView.swift", "Indicator/IndicatorWindow.swift"):
        flow = (patcher.APP / name).read_text()
        assert 'let recordingId = metricID' in flow
        assert 'recordingID: metricID' in flow
    assert 'metricID: recording.id, recordedAt: recording.timestamp' in (patcher.APP / "TranscriptionQueue.swift").read_text()
    assert 'UsageDashboardButton()' in (patcher.APP / "ContentView.swift").read_text()
    assert settings.count('OpenRouterPriceSummary(') == 1
    assert settings.count('Text(cloudModelPickerLabel(model)).tag(model.key)') == 1
    assert (patcher.APP / "Engines/OpenRouterPricing.swift").exists()
    for name in ('UsageMetrics.swift', 'UsageSelection.swift', 'UsageDashboard.swift', 'EngineChoiceSelector.swift'):
        assert (patcher.APP / 'Engines' / name).read_bytes() == (ROOT / 'src/client' / name).read_bytes()
    print("PASS fresh full patch and idempotent rerun, local engine tab, credentials, original-duration metrics, retry identity and native dashboard")
