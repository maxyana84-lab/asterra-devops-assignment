"""GeoJSON validation (RFC 7946). Pure Python, no I/O, so it is easy to unit-test."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

# How deeply the "coordinates" array is nested for each geometry type:
# 0 = a single position, 1 = a list of positions, and so on.
_COORDINATE_DEPTH = {
    "Point": 0,
    "MultiPoint": 1,
    "LineString": 1,
    "MultiLineString": 2,
    "Polygon": 2,
    "MultiPolygon": 3,
}
GEOMETRY_TYPES = {*_COORDINATE_DEPTH, "GeometryCollection"}


class GeoJSONError(ValueError):
    """The file is not valid GeoJSON. The message says what is wrong and where."""


@dataclass(frozen=True)
class Feature:
    properties: dict[str, Any]
    geometry: dict[str, Any] | None


def parse_features(raw: bytes) -> list[Feature]:
    """Parse and validate a GeoJSON document; return its features.

    Accepts a FeatureCollection, a single Feature, or a bare geometry.
    Raises GeoJSONError if the document is not valid GeoJSON.
    """
    try:
        doc = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GeoJSONError(f"not valid JSON: {exc}") from exc

    if not isinstance(doc, dict):
        raise GeoJSONError("top level must be a JSON object")

    doc_type = doc.get("type")
    if doc_type == "FeatureCollection":
        items = doc.get("features")
        if not isinstance(items, list):
            raise GeoJSONError("FeatureCollection must have a 'features' array")
        features = [_feature(item, f"features[{i}]") for i, item in enumerate(items)]
    elif doc_type == "Feature":
        features = [_feature(doc, "feature")]
    elif doc_type in GEOMETRY_TYPES:
        _check_geometry(doc, "geometry")
        features = [Feature(properties={}, geometry=doc)]
    else:
        raise GeoJSONError(f"unsupported GeoJSON type: {doc_type!r}")

    if not features:
        raise GeoJSONError("the file contains no features")
    return features


def _feature(item: Any, where: str) -> Feature:
    if not isinstance(item, dict) or item.get("type") != "Feature":
        raise GeoJSONError(f"{where}: must be an object of type 'Feature'")
    if "geometry" not in item:
        raise GeoJSONError(f"{where}: missing 'geometry' (use null for no geometry)")

    properties = item.get("properties")
    if properties is None:
        properties = {}
    if not isinstance(properties, dict):
        raise GeoJSONError(f"{where}: 'properties' must be an object or null")

    geometry = item["geometry"]
    if geometry is not None:
        _check_geometry(geometry, f"{where}.geometry")
    return Feature(properties=properties, geometry=geometry)


def _check_geometry(geom: Any, where: str) -> None:
    if not isinstance(geom, dict):
        raise GeoJSONError(f"{where}: must be an object")
    geom_type = geom.get("type")

    if geom_type == "GeometryCollection":
        members = geom.get("geometries")
        if not isinstance(members, list):
            raise GeoJSONError(f"{where}: GeometryCollection must have a 'geometries' array")
        for i, member in enumerate(members):
            _check_geometry(member, f"{where}.geometries[{i}]")
        return

    if geom_type not in _COORDINATE_DEPTH:
        raise GeoJSONError(f"{where}: unknown geometry type {geom_type!r}")

    coords = geom.get("coordinates")
    _check_coordinates(coords, _COORDINATE_DEPTH[geom_type], where)

    if geom_type == "LineString":
        _check_line(coords, where)
    elif geom_type == "MultiLineString":
        for line in coords:
            _check_line(line, where)
    elif geom_type == "Polygon":
        _check_polygon(coords, where)
    elif geom_type == "MultiPolygon":
        for polygon in coords:
            _check_polygon(polygon, where)


def _check_coordinates(coords: Any, depth: int, where: str) -> None:
    if depth == 0:
        _check_position(coords, where)
        return
    if not isinstance(coords, list):
        raise GeoJSONError(f"{where}: 'coordinates' has the wrong nesting")
    for item in coords:
        _check_coordinates(item, depth - 1, where)


def _check_position(pos: Any, where: str) -> None:
    if not isinstance(pos, list) or len(pos) not in (2, 3):
        raise GeoJSONError(f"{where}: a position must be [lon, lat] or [lon, lat, elevation]")
    for value in pos:
        # bool is a subclass of int in Python, so exclude it explicitly.
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise GeoJSONError(f"{where}: coordinates must be numbers")
    lon, lat = pos[0], pos[1]
    if not -180 <= lon <= 180 or not -90 <= lat <= 90:
        raise GeoJSONError(f"{where}: position {pos[:2]} is outside the WGS 84 range")


def _check_line(line: list, where: str) -> None:
    if len(line) < 2:
        raise GeoJSONError(f"{where}: a line needs at least 2 positions")


def _check_polygon(rings: list, where: str) -> None:
    if not rings:
        raise GeoJSONError(f"{where}: a polygon needs at least one ring")
    for ring in rings:
        if len(ring) < 4:
            raise GeoJSONError(f"{where}: a polygon ring needs at least 4 positions")
        if ring[0] != ring[-1]:
            raise GeoJSONError(f"{where}: a polygon ring must be closed")
