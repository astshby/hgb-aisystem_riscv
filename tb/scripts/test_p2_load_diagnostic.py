#!/usr/bin/env python3
"""Reject absent/contaminated isolated loads and inconsistent clock records."""
import copy
import importlib.util
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('load_diagnostic',ROOT/'scripts/verilator/run_p2_load_diagnostic.py')
diag=importlib.util.module_from_spec(spec);spec.loader.exec_module(diag)

class DiagnosticTests(unittest.TestCase):
    def fixture(self,mode):
        hardware=diag.p2.soc_build_configuration(1,8)
        values={'errors':0,'core_cycles':1234,'irq':16 if mode=='irq_only' else 0,
                'dma_completed':8 if mode=='dma_only' else 0,'dma_bytes':131072 if mode=='dma_only' else 0,
                'core_hz':100000000,'timer_hz':25000000,'interval_ticks':2500}
        metrics={'axi':{'sys.master2':{'roi_rbeats':4096 if mode=='dma_only' else 0,
                                     'roi_wbeats':4096 if mode=='dma_only' else 0}}}
        return values,hardware,metrics
    def test_two_valid_isolated_modes(self):
        for mode in ('irq_only','dma_only'):
            values,hardware,metrics=self.fixture(mode)
            diag.validate_activity(values,mode,hardware,1,metrics)
    def test_missing_or_failed_interrupts_rejected(self):
        values,hardware,metrics=self.fixture('irq_only')
        for field,value in (('irq',0),('errors',1),('dma_completed',1),('dma_bytes',4),('core_cycles',0)):
            changed={**values,field:value}
            with self.subTest(field=field),self.assertRaises(ValueError):
                diag.validate_activity(changed,'irq_only',hardware,1,metrics)
    def test_dma_polling_must_not_generate_interrupts(self):
        values,hardware,metrics=self.fixture('dma_only');values['irq']=1
        with self.assertRaises(ValueError):diag.validate_activity(values,'dma_only',hardware,1,metrics)
    def test_dma_payload_must_complete_inside_roi(self):
        values,hardware,metrics=self.fixture('dma_only')
        for field in ('roi_rbeats','roi_wbeats'):
            changed=copy.deepcopy(metrics);changed['axi']['sys.master2'][field]-=1
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'complete payload'):
                diag.validate_activity(values,'dma_only',hardware,1,changed)
    def test_irq_only_rejects_hidden_dma(self):
        values,hardware,metrics=self.fixture('irq_only');metrics['axi']['sys.master2']['roi_wbeats']=1
        with self.assertRaisesRegex(ValueError,'unexpectedly issued DMA'):
            diag.validate_activity(values,'irq_only',hardware,1,metrics)
    def test_clock_and_interval_mismatch_rejected(self):
        values,hardware,metrics=self.fixture('irq_only')
        for field in ('core_hz','timer_hz','interval_ticks'):
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'clock contract'):
                diag.validate_activity({**values,field:values[field]+1},'irq_only',hardware,1,metrics)
        with self.assertRaisesRegex(ValueError,'clock contract'):
            diag.validate_activity(values,'irq_only',hardware,4,metrics)

if __name__=='__main__':unittest.main(verbosity=2)
