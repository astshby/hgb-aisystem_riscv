"""Small native C checks for the real board bridge, its pool and image preprocessing."""
import ctypes
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class YoloServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        output = Path(os.environ.get("YDM_SERVICE_TEST_OUT", ROOT / "build/yolo/service-tests"))
        output.mkdir(parents=True, exist_ok=True)
        library = output / "service.so"
        subprocess.run(["cc", "-std=c11", "-O3", "-ffp-contract=off", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        "-Isoftware/yolo", "software/yolo/network_pool.c", "software/yolo/network_service.c",
                        "software/yolo/network.c", "software/yolo/video_service.c", "software/yolo/conv_schedule.c", "tb/scripts/yolo_service_checks.c",
                        "-lm", "-o", str(library)], cwd=ROOT, check=True)
        cls.lib = ctypes.CDLL(str(library))

    def check(self, name):
        self.assertEqual(getattr(self.lib, "check_" + name)(), 0, "C check returned a failing source line")

    def test_pool_alignment(self): self.check("pool_alignment")
    def test_pool_adjacent_blocks_merge(self): self.check("pool_coalesce")
    def test_pool_thousand_reuse_cycles(self): self.check("pool_repeated")
    def test_pool_exhaustion_and_zero_allocation(self): self.check("pool_exhaustion")
    def test_preprocess_exact_rgb_identity(self): self.check("preprocess_identity")
    def test_preprocess_bilinear_small_average(self): self.check("preprocess_average")
    def test_preprocess_top_left_pad114(self): self.check("preprocess_padding")
    def test_preprocess_single_pixel_edges(self): self.check("preprocess_single_pixel")
    def test_preprocess_invalid_size(self): self.check("preprocess_bounds")
    def test_draw_clipped_rectangle(self): self.check("draw_clipping")
    def test_cached_detect_avoids_reinferring_annotated_frame(self): self.check("service_cache")

    @unittest.skipUnless(os.environ.get("YDM_NETWORK_MODEL"), "set YDM_NETWORK_MODEL for real package publication")
    def test_real_model_publication_and_npu_failure_cleanup(self):
        function = self.lib.check_service_real_model
        function.argtypes = [ctypes.c_char_p]
        function.restype = ctypes.c_int
        self.assertEqual(function(os.fsencode(os.environ["YDM_NETWORK_MODEL"])), 0)


if __name__ == "__main__": unittest.main()
