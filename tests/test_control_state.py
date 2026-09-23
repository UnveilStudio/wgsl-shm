"""
Test della logica di controllo che non tocca la GPU.

Copre i tre punti dove un errore si vedrebbe solo dal vivo: il clamp dei
parametri al cambio shader, la scadenza del lock degli slider, e il parsing
degli argomenti OSC.

    python -m pytest tests/ -q
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from control.server import ShaderControlState
from control.osc_input import _coerce


def _schema(name, uniforms):
    return {"name": name, "shader": name + ".wgsl", "uniforms": uniforms}


@pytest.fixture
def shaders(tmp_path):
    """Due shader con range deliberatamente diversi, come i veri."""
    wide = _schema("wide", [
        {"name": "scale",   "type": "float", "min": 1.0, "max": 20.0, "default": 5.0},
        {"name": "octaves", "type": "int",   "min": 3,   "max": 12,   "default": 6},
        {"name": "col_a",   "type": "color", "default": [0.1, 0.2, 0.3]},
    ])
    narrow = _schema("narrow", [
        {"name": "scale",   "type": "float", "min": 0.2, "max": 6.0, "default": 2.5},
        {"name": "octaves", "type": "int",   "min": 1,   "max": 4,   "default": 2},
        {"name": "col_a",   "type": "color", "default": [0.9, 0.9, 0.9]},
    ])
    for s in (wide, narrow):
        (tmp_path / (s["name"] + ".json")).write_text(json.dumps(s), encoding="utf-8")
        (tmp_path / (s["name"] + ".wgsl")).write_text("// stub", encoding="utf-8")
    return tmp_path


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def advance(self, dt):
        self.t += dt


# --- cambio shader: conservare senza uscire dai range ----------------------

def test_valori_sopravvivono_al_cambio_shader(shaders):
    st = ShaderControlState(str(shaders / "wide.json"))
    st.set_value("scale", 12.0)
    st.switch_schema("narrow")
    # 12 non entra in (0.2, 6.0): conservato ma clampato, non azzerato
    assert st.get_value("scale") == 6.0


def test_valore_gia_valido_resta_intatto(shaders):
    st = ShaderControlState(str(shaders / "wide.json"))
    st.set_value("scale", 4.0)
    st.switch_schema("narrow")
    assert st.get_value("scale") == 4.0


def test_clamp_verso_il_basso_al_minimo_del_nuovo_schema(shaders):
    st = ShaderControlState(str(shaders / "narrow.json"))
    st.set_value("octaves", 2)
    st.switch_schema("wide")          # wide vuole almeno 3
    assert st.get_value("octaves") == 3


def test_octaves_resta_intero(shaders):
    st = ShaderControlState(str(shaders / "wide.json"))
    st.set_value("octaves", 7.6)
    assert isinstance(st.get_value("octaves"), int)
    assert st.get_value("octaves") == 8


def test_colori_passano_senza_clamp(shaders):
    st = ShaderControlState(str(shaders / "wide.json"))
    st.set_value("col_a", [0.4, 0.5, 0.6])
    st.switch_schema("narrow")
    assert st.get_value("col_a") == [0.4, 0.5, 0.6]


def test_set_value_clampa_subito(shaders):
    st = ShaderControlState(str(shaders / "narrow.json"))
    st.set_value("scale", 999.0)
    assert st.get_value("scale") == 6.0


# --- lock degli slider -----------------------------------------------------

def test_osc_blocca_il_parametro(shaders):
    st = ShaderControlState(str(shaders / "wide.json"), clock=FakeClock())
    st.set_value("scale", 3.0, source="osc")
    assert st.external_locks() == ["scale"]


def test_il_panel_non_blocca_se_stesso(shaders):
    st = ShaderControlState(str(shaders / "wide.json"), clock=FakeClock())
    st.set_value("scale", 3.0, source="panel")
    assert st.external_locks() == []


def test_il_lock_scade_nel_silenzio(shaders):
    clock = FakeClock()
    st = ShaderControlState(str(shaders / "wide.json"), clock=clock)
    st.set_value("scale", 3.0, source="osc")
    clock.advance(1.9)
    assert st.external_locks() == ["scale"], "TD sta ancora mandando"
    clock.advance(0.2)
    assert st.external_locks() == [], "TD ha smesso: si riprende il controllo"


def test_il_lock_si_rinnova_a_ogni_messaggio(shaders):
    clock = FakeClock()
    st = ShaderControlState(str(shaders / "wide.json"), clock=clock)
    for _ in range(5):
        st.set_value("scale", 3.0, source="osc")
        clock.advance(1.0)
    assert st.external_locks() == ["scale"]


# --- coda del live coding --------------------------------------------------

def test_shader_code_si_consuma_una_volta_sola(shaders):
    st = ShaderControlState(str(shaders / "wide.json"))
    assert st.pop_shader_code() is None
    st.push_shader_code("// wgsl", client="c")
    assert st.pop_shader_code() == ("// wgsl", "c")
    assert st.pop_shader_code() is None


# --- parsing OSC -----------------------------------------------------------

@pytest.mark.parametrize("args, expected", [
    ((1.7,),               1.7),
    ((3,),                 3.0),
    ((0.1, 0.2, 0.3),      [0.1, 0.2, 0.3]),
    ((),                   None),
    (("ciao",),            None),
    ((1.0, 2.0),           None),      # 2 argomenti: ne' scalare ne' colore
    ((1.0, "x", 3.0),      None),
])
def test_coerce_osc(args, expected):
    got = _coerce(args)
    if isinstance(expected, list):
        assert got == pytest.approx(expected)
    elif expected is None:
        assert got is None
    else:
        assert got == pytest.approx(expected)
