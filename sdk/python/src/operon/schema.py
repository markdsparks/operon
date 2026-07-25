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
    "minItems",
    "maxItems",
    "$defs",
    "$ref",
}
_SUPPORTED_TYPES = {"object", "array", "string", "number", "integer", "boolean", "null"}


def validate_schema_definition(
    schema: Any,
    path: str = "output_schema",
    *,
    _root: dict[str, Any] | None = None,
    _references: tuple[str, ...] = (),
    _depth: int = 0,
) -> list[str]:
    """Validate the deliberately small JSON Schema subset Operon enforces."""
    if not isinstance(schema, dict):
        return [f"{path} must be an object"]
    if _depth > 32:
        return [f"{path} exceeds the maximum schema depth"]
    root = schema if _root is None else _root
    errors: list[str] = []
    unsupported = set(schema) - _SUPPORTED_KEYS
    if unsupported:
        errors.append(f"{path} uses unsupported keywords: {', '.join(sorted(unsupported))}")
    if "$ref" in schema:
        reference = schema["$ref"]
        if not isinstance(reference, str):
            return [f"{path}.$ref must be a string"]
        if len(schema) != 1:
            errors.append(f"{path}.$ref cannot have sibling keywords")
        if reference in _references:
            errors.append(f"{path} contains a cyclic reference: {reference}")
            return errors
        target = _resolve_local_reference(root, reference)
        if target is None:
            errors.append(f"{path} references an unknown local definition: {reference}")
            return errors
        errors.extend(
            validate_schema_definition(
                target,
                f"{path}.$ref",
                _root=root,
                _references=(*_references, reference),
                _depth=_depth + 1,
            )
        )
        return errors
    definitions = schema.get("$defs", {})
    if not isinstance(definitions, dict):
        errors.append(f"{path}.$defs must be an object")
        definitions = {}
    for name, definition in definitions.items():
        errors.extend(
            validate_schema_definition(
                definition,
                f"{path}.$defs.{name}",
                _root=root,
                _references=_references,
                _depth=_depth + 1,
            )
        )
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
            errors.extend(
                validate_schema_definition(
                    child,
                    f"{path}.{name}",
                    _root=root,
                    _references=_references,
                    _depth=_depth + 1,
                )
            )
    elif schema_type == "array":
        for bound in ("minItems", "maxItems"):
            if bound in schema and (
                not isinstance(schema[bound], int)
                or isinstance(schema[bound], bool)
                or schema[bound] < 0
            ):
                errors.append(f"{path}.{bound} must be a non-negative integer")
        if (
            isinstance(schema.get("minItems"), int)
            and isinstance(schema.get("maxItems"), int)
            and schema["minItems"] > schema["maxItems"]
        ):
            errors.append(f"{path}.minItems cannot exceed maxItems")
        if "items" not in schema:
            errors.append(f"{path}.items is required for arrays")
        else:
            errors.extend(
                validate_schema_definition(
                    schema["items"],
                    f"{path}.items",
                    _root=root,
                    _references=_references,
                    _depth=_depth + 1,
                )
            )
    return errors


def validate_instance(
    value: Any,
    schema: dict[str, Any],
    path: str = "output",
    *,
    _root: dict[str, Any] | None = None,
    _references: tuple[str, ...] = (),
    _depth: int = 0,
) -> list[str]:
    if _depth > 32:
        return [f"{path} exceeds the maximum schema depth"]
    root = schema if _root is None else _root
    if "$ref" in schema:
        reference = schema["$ref"]
        if reference in _references:
            return [f"{path} contains a cyclic reference: {reference}"]
        target = _resolve_local_reference(root, reference)
        if target is None:
            return [f"{path} references an unknown local definition: {reference}"]
        return validate_instance(
            value,
            target,
            path,
            _root=root,
            _references=(*_references, reference),
            _depth=_depth + 1,
        )
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
                errors.extend(
                    validate_instance(
                        value[name],
                        child,
                        f"{path}.{name}",
                        _root=root,
                        _references=_references,
                        _depth=_depth + 1,
                    )
                )
    elif schema_type == "array":
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path} contains fewer than minItems")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path} contains more than maxItems")
        for index, item in enumerate(value):
            errors.extend(
                validate_instance(
                    item,
                    schema["items"],
                    f"{path}[{index}]",
                    _root=root,
                    _references=_references,
                    _depth=_depth + 1,
                )
            )
    return errors


def _resolve_local_reference(root: dict[str, Any], reference: str) -> Any | None:
    if not reference.startswith("#/"):
        return None
    current: Any = root
    for token in reference[2:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or token not in current:
            return None
        current = current[token]
    return current


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
