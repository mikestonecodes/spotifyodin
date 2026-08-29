package spoticyclint

import "core:encoding/json"

jget :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, is_obj := v.(json.Object)
	if !is_obj do return nil, false
	x, found := o[key]
	return x, found
}

jstr :: proc(v: json.Value, key: string) -> string {
	x, found := jget(v, key)
	if !found do return ""
	s, is_str := x.(json.String)
	if !is_str do return ""
	return string(s)
}

jnum :: proc(v: json.Value, key: string) -> int {
	x, found := jget(v, key)
	if !found do return 0
	switch n in x {
	case json.Float:
		return int(n)
	case json.Integer:
		return int(n)
	case json.Null, json.Boolean, json.String, json.Array, json.Object:
	}
	return 0
}

jarr :: proc(v: json.Value, key: string) -> []json.Value {
	x, found := jget(v, key)
	if !found do return nil
	a, is_arr := x.(json.Array)
	if !is_arr do return nil
	return a[:]
}

jbool :: proc(v: json.Value, key: string) -> bool {
	x, found := jget(v, key)
	if !found do return false
	b, is_bool := x.(json.Boolean)
	if !is_bool do return false
	return bool(b)
}

// Nested lookup: jpath(v, "item", "album") etc.
jpath :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys {
		x, found := jget(cur, k)
		if !found do return nil
		cur = x
	}
	return cur
}
