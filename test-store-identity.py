import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('bridge',str(Path(__file__).with_name('windows-build.py')))
bridge=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class StoreIdentityTests(unittest.TestCase):
    def test_requires_signed_versioned_package(self):
        for flags in [[], ['--build-only'], ['--no-sign'], ['--dev','--no-sign']]:
            with self.subTest(flags=flags), patch.object(sys,'argv',['bridge','--repo','/tmp','--store-identity',*flags]):
                with self.assertRaises(SystemExit): bridge.parse_arguments()
        for flags in [['--install'],['--dev'],['--install','--skip-build']]:
            with patch.object(sys,'argv',['bridge','--repo','/tmp','--store-identity',*flags]):
                self.assertTrue(bridge.parse_arguments().store_identity)

    def test_reuse_cannot_cross_package_families(self):
        with tempfile.TemporaryDirectory() as root:
            repo=Path(root)
            for name,store_mode,success in [('01-dev',False,True),('02-store',True,True),('03-failed',True,False)]:
                out=repo/'.artifacts/windows-build'/name
                out.mkdir(parents=True)
                report=dict(success=success,dev=True,platform='ARM64',store_identity=store_mode)
                (out/'result.json').write_text(json.dumps(report))
            self.assertEqual(bridge.latest_dev_package(repo,'ARM64').name,'01-dev')
            self.assertEqual(bridge.latest_dev_package(repo,'ARM64',True).name,'02-store')
            with self.assertRaises(FileNotFoundError): bridge.latest_dev_package(repo,'x64',True)

if __name__=='__main__': unittest.main(verbosity=2)
