#!/usr/bin/env python3
"""Offline unit checks for publication and release tooling; no signing or network."""
import importlib.util
import hashlib
import contextlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load("source_checks_test", "check-source.py")
release = load("release_verifier_test", "verify-release.py")
metadata = load("release_metadata_test", "release-metadata.py")
licenses = load("license_checks_test", "check-licenses.py")
audio_generator = load("local_audio_generator_test", "generate-local-audio-fixtures.py")


class ReleaseArchiveScriptTests(unittest.TestCase):
    def fixture(self, root):
        scripts = root / 'scripts'
        scripts.mkdir()
        script = scripts / 'build-release.sh'
        shutil.copyfile(Path(__file__).with_name('build-release.sh'), script)
        commands = root / 'commands'
        commands.mkdir()
        python = commands / 'python3'
        python.write_text('#!/bin/sh\nexit 0\n')
        xcode = commands / 'xcodebuild'
        xcode.write_text(f'#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["MACAPY_FAKE_XCODE_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n')
        python.chmod(0o755); xcode.chmod(0o755)
        arguments = root / 'arguments.json'
        env = {'PATH': str(commands) + ':/usr/bin:/bin', 'MACAPY_FAKE_XCODE_ARGS': str(arguments)}
        return script, arguments, env

    def test_existing_cache_is_one_quoted_argument_with_pinned_unsigned_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, arguments, env = self.fixture(root)
            cache = root / 'existing packages'
            cache.mkdir()
            env['MACAPY_SOURCE_PACKAGES'] = str(cache)
            result = subprocess.run(['/bin/bash', str(script), '--output', str(root / 'candidate')],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads(arguments.read_text())
            self.assertEqual(Path(args[args.index('-clonedSourcePackagesDirPath') + 1]).resolve(), cache.resolve())
            for flag in ['-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates', 'CODE_SIGNING_ALLOWED=NO', 'archive']:
                self.assertIn(flag, args)

    def test_missing_cache_fails_before_creating_output_or_invoking_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, arguments, env = self.fixture(root)
            env['MACAPY_SOURCE_PACKAGES'] = str(root / 'missing')
            output = root / 'candidate'
            result = subprocess.run(['/bin/bash', str(script), '--output', str(output)],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())
            self.assertFalse(arguments.exists())


class LocalAudioGeneratorTests(unittest.TestCase):
    def test_generator_requires_exact_opt_in_before_touching_voice_tools(self):
        with patch.dict('os.environ', {}, clear=True), patch('sys.argv', ['generator', '/tmp/unused']), \
             patch.object(audio_generator.subprocess, 'check_output') as command, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                audio_generator.main()
            command.assert_not_called()

    def test_generator_never_overwrites_existing_local_evidence(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', {'MACAPY_GENERATE_LOCAL_AUDIO': '1'}), \
             patch('sys.argv', ['generator', directory]), patch.object(audio_generator.subprocess, 'check_output') as command, \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                audio_generator.main()
            command.assert_not_called()


class LicenseInventoryTests(unittest.TestCase):
    def fixture(self, root):
        (root / "scripts").mkdir()
        (root / "Tests/Example/Fixtures").mkdir(parents=True)
        (root / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "example", "state": {"revision": "abc"}}]}))
        (root / "THIRD_PARTY_NOTICES.md").write_text("abc original license text")
        (root / "LICENSE.txt").write_text("original license text")
        value = {"pins": {"example": "abc"}, "notices": [{"path": "LICENSE.txt", "sha256": hashlib.sha256(b"original license text").hexdigest()}], "assets": [], "pending_release_reviews": []}
        (root / "scripts/license-inventory.json").write_text(json.dumps(value))
        return value

    def test_changed_dependency_and_missing_full_notice_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.assertEqual(licenses.check_licenses(root), ([], []))
            (root / "THIRD_PARTY_NOTICES.md").write_text("abc")
            self.assertTrue(licenses.check_licenses(root)[0])
            (root / "Package.resolved").write_text(json.dumps({"pins": []}))
            self.assertTrue(licenses.check_licenses(root)[0])

    def test_new_audio_is_never_silently_exempted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / "Tests/Example/Fixtures/new.wav").write_bytes(b"synthetic")
            self.assertTrue(licenses.check_licenses(root)[0])

    def test_pending_review_is_not_release_clearance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = self.fixture(root)
            value["pending_release_reviews"] = ["Specific unresolved asset terms"]
            (root / "scripts/license-inventory.json").write_text(json.dumps(value))
            self.assertFalse(licenses.check_licenses(root)[0])
            self.assertTrue(licenses.check_licenses(root, strict_release=True)[0])


class SourceBoundaryTests(unittest.TestCase):
    def test_secret_diagnostic_never_echoes_matched_token(self):
        token = "ghp_" + "Z" * 36
        errors = source.check_text("example.swift", "let key = \"" + token + "\"")
        self.assertTrue(errors)
        self.assertNotIn(token, " ".join(errors))

    def test_synthetic_canary_is_allowed_but_not_arbitrary_provider_keys(self):
        self.assertFalse(source.check_text("example.swift", "sk-" + "0" * 32))
        self.assertTrue(source.check_text("example.swift", "sk-" + "a1" * 16))

    def test_author_specific_paths_fail(self):
        self.assertTrue(source.check_text("README.md", "/Users" + "/example/work/project"))

    def test_production_graph_checks_transitive_edges(self):
        graph = {"products": [{"targets": ["AppShell"]}], "targets": [
            {"name": "AppShell", "type": "regular", "dependencies": [{"byName": ["Bridge", None]}]},
            {"name": "Bridge", "type": "regular", "dependencies": [{"target": ["ProviderTestSupport", None]}]},
            {"name": "ProviderTestSupport", "type": "regular", "dependencies": []},
        ]}
        self.assertTrue(source.check_production_graph(graph))
        graph["targets"][1]["dependencies"] = []
        self.assertFalse(source.check_production_graph(graph))

    def test_graph_rejects_any_test_target_even_with_another_name(self):
        graph = {"products": [{"targets": ["UnexpectedTests"]}], "targets": [
            {"name": "UnexpectedTests", "type": "test", "dependencies": []},
        ]}
        self.assertTrue(source.check_production_graph(graph))

    def test_local_links_private_paths_missing_paths_and_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide").mkdir()
            (root / "guide/development.md").write_text("build")
            path = root / "README.md"
            self.assertFalse(source.check_markdown(root, path, "[Build](guide/development.md#build)"))
            for target in ["docs/architecture.md", "missing.md", "../outside.md"]:
                self.assertTrue(source.check_markdown(root, path, f"[Bad]({target})"))
            self.assertFalse(source.check_markdown(root, path, "[Remote](https://example.com/no-fetch)"))

    def test_lock_origin_hash_can_differ_but_revision_cannot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin = {"identity": "library", "kind": "remoteSourceControl", "location": "https://example.com/library", "state": {"revision": "abc", "version": "1.0.0"}}
            paths = [root / name for name in source.LOCK_PATHS]
            for index, path in enumerate(paths):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({"originHash": str(index), "pins": [pin]}))
            self.assertFalse(source.check_locks(root))
            pin["state"]["revision"] = "def"
            paths[1].write_text(json.dumps({"pins": [pin]}))
            self.assertTrue(source.check_locks(root))

    def test_resolved_workspace_must_match_lockfile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin = {"identity": "library", "kind": "remoteSourceControl", "location": "https://example.com/library", "state": {"revision": "abc", "version": "1.0.0"}}
            for name in source.LOCK_PATHS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({"pins": [pin]}))
            (root / ".build").mkdir()
            (root / ".build/workspace-state.json").write_text(json.dumps({"object": {"dependencies": []}}))
            self.assertTrue(source.check_locks(root))


class ReleaseEvidenceTests(unittest.TestCase):
    def test_required_notices_are_inside_bundle_and_match_captured_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'macapy.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            source = {'files': []}
            self.assertEqual(len(release.validate_notices(app)), 2)
            for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
                payload = ('synthetic ' + name).encode()
                (resources / name).write_bytes(payload)
                source['files'].append({'path': name, 'sha256': hashlib.sha256(payload).hexdigest()})
            self.assertFalse(release.validate_notices(app, source))
            (resources / 'LICENSE').write_text('changed')
            self.assertTrue(release.validate_notices(app, source))

    def test_hardened_capture_requires_audio_input_and_rejects_debug_exceptions(self):
        self.assertTrue(release.validate_entitlements({}))
        self.assertFalse(release.validate_entitlements({"com.apple.security.device.audio-input": True}))
        self.assertTrue(release.validate_entitlements({
            "com.apple.security.device.audio-input": True,
            "com.apple.security.get-task-allow": True,
        }))

    def test_unresolved_build_metadata_cannot_be_packaged_as_verified(self):
        self.assertTrue(release.validate_metadata({"CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"}))

    def test_expected_bundle_metadata_passes(self):
        self.assertFalse(release.validate_metadata({
            "CFBundleIdentifier": "io.macapy.app", "CFBundleExecutable": "macapy",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "26.0", "NSMicrophoneUsageDescription": "Microphone",
            "NSAudioCaptureUsageDescription": "System audio",
            "NSCalendarsWriteOnlyAccessUsageDescription": "Create reviewed events",
            "NSCalendarsFullAccessUsageDescription": "Read selected calendars",
            "NSRemindersFullAccessUsageDescription": "Create reviewed reminders",
        }))

    def test_eventkit_scopes_each_require_their_own_usage_description(self):
        errors = release.validate_metadata({"NSCalendarsUsageDescription": "Old shared description"})
        for key in ("NSCalendarsWriteOnlyAccessUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription"):
            self.assertTrue(any(key in error for error in errors))

    def test_source_digest_changes_for_new_uncommitted_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "source.swift"
            file.write_text("first")
            for name in source.LOCK_PATHS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}")
            with patch.object(metadata.checks, "public_files", return_value=[file]), patch.object(metadata.checks, "run", return_value="dirty"):
                before = metadata.snapshot(root)
                file.write_text("second")
                after = metadata.snapshot(root)
            self.assertNotEqual(before["public_source_sha256"], after["public_source_sha256"])
            self.assertTrue(after["has_local_changes"])


if __name__ == "__main__":
    unittest.main()
