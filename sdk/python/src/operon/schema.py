from __future__ import annotations

from typing import Any


_SUPPORTED_KEYS = {
    "type",
    "title",
    "description",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "enum",
    "minimum",
    "maximum",
}
_SUPPORTED_TYPES = {"object", "array", "string", "number", "integer", "boolean", "null"}


def validate_schema_definition(schema: Any, path: str = "output_schema") -> list[str]:
    """Validate the deliberately small JSON Schema subset Operon enforces."""
    if not isinstance(schema, dict):
        return [f"{path} must be an object"]
    errors: list[str] = []
    unsupported = set(schema) - _SUPPORTED_KEYS
    if unsupported:
        errors.append(f"{path} uses unsupported keywords: {', '.join(sorted(unsupported))}")
    schema_type = schema.get("type")
    if schema_type not in _SUPPORTED_TYPES:
        errors.append(f"{path}.type must be one of {', '.join(sorted(_SUPPORTED_TYPES))}")
        return errors
    if "enum" in schema and (
        not isinstance(schema["enum"], list) or not schema["enum"]
    ):
        errors.append(f"{path}.enum must be a non-empty array")
    for bound in ("minimum", "maximum"):
        if bound in schema and not _is_number(schema[bound]):
            errors.append(f"{path}.{bound} must be a number")
    if schema_type == "object":
        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            errors.append(f"{path}.properties must be an object")
            properties = {}
        additional = schema.get("additionalProperties", True)
        if not isinstance(additional, bool):
            errors.append(f"{path}.additionalProperties must be a boolean")
        required = schema.get("required", [])
        if not isinstance(required, list) or not all(
            isinstance(item, str) for item in required
        ):
            errors.append(f"{path}.required must be an array of strings")
        else:
            unknown = set(required) - set(properties)
            if unknown:
                errors.append(
                    f"{path}.required names unknown properties: {', '.join(sorted(unknown))}"
                )
        for name, child in properties.items():
            errors.extend(validate_schema_definition(child, f"{path}.{name}"))
    elif schema_type == "array":
        if "items" not in schema:
            errors.append(f"{path}.items is required for arrays")
        else:
            errors.extend(validate_schema_definition(schema["items"], f"{path}.items"))
    return errors


def validate_instance(value: Any, schema: dict[str, Any], path: str = "output") -> list[str]:
    errors: list[str] = []
    schema_type = schema["type"]
    if not _matches_type(value, schema_type):
        return [f"{path} must be {article(schema_type)} {schema_type}"]
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path} must be one of {schema['enum']!r}")
    if schema_type in {"number", "integer"}:
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path} must be at least {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path} must be at most {schema['maximum']}")
    elif schema_type == "object":
        properties = schema.get("properties", {})
        missing = [name for name in schema.get("required", []) if name not in value]
        for name in missing:
            errors.append(f"{path}.{name} is required")
        if schema.get("additionalProperties", True) is False:
            for name in set(value) - set(properties):
                errors.append(f"{path}.{name} is not allowed")
        for name, child in properties.items():
            if name in value:
                errors.extend(validate_instance(value[name], child, f"{path}.{name}"))
    elif schema_type == "array":
        for index, item in enumerate(value):
            errors.extend(validate_instance(item, schema["items"], f"{path}[{index}]"))
    return errors


def _matches_type(value: Any, schema_type: str) -> bool:
    if schema_type == "object":
        return isinstance(value, dict)
    if schema_type == "array":
        return isinstance(value, list)
    if schema_type == "string":
        return isinstance(value, str)
    if schema_type == "number":
        return _is_number(value)
    if schema_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if schema_type == "boolean":
        return isinstance(value, bool)
    return value is None


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def article(word: str) -> str:
    return "an" if word[0] in "aeiou" else "a"
