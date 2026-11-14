import json
from pathlib import Path

import pytest

from geoloader.validation import GeoJSONError, parse_features

SAMPLES = Path(__file__).parent.parent / "samples"


def doc(obj) -> bytes:
    return json.dumps(obj).encode()


def feature(geometry, properties=None):
    return {"type": "Feature", "properties": properties, "geometry": geometry}


def test_sample_valid_file_has_three_features():
    features = parse_features((SAMPLES / "valid.geojson").read_bytes())
    assert [f.geometry["type"] for f in features] == ["Point", "LineString", "Polygon"]
    assert features[0].properties["name"] == "ASTERRA office"


def test_sample_invalid_file_is_rejected():
    with pytest.raises(GeoJSONError, match="closed"):
        parse_features((SAMPLES / "invalid.geojson").read_bytes())


def test_single_feature_is_accepted():
    features = parse_features(doc(feature({"type": "Point", "coordinates": [1, 2]})))
    assert len(features) == 1
    assert features[0].properties == {}


def test_bare_geometry_is_wrapped_in_a_feature():
    features = parse_features(doc({"type": "Point", "coordinates": [1, 2, 30]}))
    assert features[0].geometry["type"] == "Point"


def test_null_geometry_is_allowed():
    assert parse_features(doc(feature(None, {"a": 1})))[0].geometry is None


def test_geometry_collection_is_checked_recursively():
    good = {"type": "GeometryCollection", "geometries": [{"type": "Point", "coordinates": [1, 2]}]}
    assert len(parse_features(doc(feature(good)))) == 1

    bad = {"type": "GeometryCollection", "geometries": [{"type": "Point", "coordinates": [1]}]}
    with pytest.raises(GeoJSONError, match="position"):
        parse_features(doc(feature(bad)))


@pytest.mark.parametrize(
    ("raw", "message"),
    [
        (b"not json at all", "not valid JSON"),
        (b"\xff\xfe\x00", "not valid JSON"),
        (doc([1, 2, 3]), "top level"),
        (doc({"type": "Banana"}), "unsupported GeoJSON type"),
        (doc({"type": "FeatureCollection"}), "'features' array"),
        (doc({"type": "FeatureCollection", "features": []}), "no features"),
        (doc({"type": "FeatureCollection", "features": [{"type": "Point"}]}), "type 'Feature'"),
        (doc({"type": "Feature", "properties": {}}), "missing 'geometry'"),
        (doc(feature({"type": "Point", "coordinates": [1, 2]}, "text")), "'properties'"),
        (doc(feature({"type": "Circle", "coordinates": [1, 2]})), "unknown geometry type"),
        (doc(feature({"type": "Point", "coordinates": ["1", "2"]})), "must be numbers"),
        (doc(feature({"type": "Point", "coordinates": [True, 2]})), "must be numbers"),
        (doc(feature({"type": "Point", "coordinates": [200, 10]})), "outside the WGS 84 range"),
        (doc(feature({"type": "Point", "coordinates": [10, 95]})), "outside the WGS 84 range"),
        (doc(feature({"type": "Point"})), "position"),
        (doc(feature({"type": "LineString", "coordinates": [[1, 2]]})), "at least 2 positions"),
        (doc(feature({"type": "LineString", "coordinates": [1, 2]})), "position"),
        (doc(feature({"type": "Polygon", "coordinates": []})), "at least one ring"),
        (
            doc(feature({"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [0, 0]]]})),
            "at least 4 positions",
        ),
        (
            doc(
                feature(
                    {"type": "MultiPolygon", "coordinates": [[[[0, 0], [1, 0], [1, 1], [0, 1]]]]}
                )
            ),
            "closed",
        ),
    ],
)
def test_invalid_documents_are_rejected(raw, message):
    with pytest.raises(GeoJSONError, match=message):
        parse_features(raw)
