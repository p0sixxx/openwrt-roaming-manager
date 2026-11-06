# shellcheck shell=sh
# OpenWrt Roaming Manager - minimal JSON reader
#
# ubus prints JSON. Instead of spawning jsonfilter many times, documents
# are flattened once by a small awk parser into "path=value" lines:
#
#   {"radio0":{"up":true,"interfaces":[{"ifname":"phy0-ap0"}]}}
#   -> radio0.up=true
#      radio0.interfaces.0.ifname=phy0-ap0
#
# String escapes \" \\ \/ \n \t are decoded, \uXXXX is kept verbatim.
# Works with BusyBox awk, mawk and gawk.

json_flatten() {
	awk '
	function emit(v) { print path_str() "=" v }
	function path_str(   i, s) {
		s = ""
		for (i = 1; i <= depth; i++) {
			if (i > 1) s = s "."
			s = s key[i]
		}
		return s
	}
	BEGIN { depth = 0; buf = "" }
	{ buf = buf $0 "\n" }
	END {
		n = length(buf); i = 1
		while (i <= n) {
			c = substr(buf, i, 1)
			if (c == "{" || c == "[") {
				has[depth] = 1
				depth++
				has[depth] = 0
				type[depth] = c
				idx[depth] = 0
				key[depth] = (c == "[") ? "0" : ""
				expect_key[depth] = (c == "{")
				i++; continue
			}
			if (c == "}" || c == "]") {
				# empty containers are reported so their keys are known
				if (!has[depth] && depth > 1) { depth--; print path_str() "=" (c == "]" ? "[]" : "{}"); i++; continue }
				depth--; i++; continue
			}
			if (c == ",") {
				if (type[depth] == "[") { idx[depth]++; key[depth] = idx[depth] }
				else expect_key[depth] = 1
				i++; continue
			}
			if (c == ":") { i++; continue }
			if (c == "\"") {
				# read string
				s = ""; i++
				while (i <= n) {
					c = substr(buf, i, 1)
					if (c == "\\") {
						d = substr(buf, i + 1, 1)
						if (d == "n") s = s "\\n"
						else if (d == "t") s = s "\t"
						else if (d == "u") s = s "\\u"
						else s = s d
						i += 2; continue
					}
					if (c == "\"") { i++; break }
					s = s c; i++
				}
				if (type[depth] == "{" && expect_key[depth]) {
					key[depth] = s; expect_key[depth] = 0
				} else { has[depth] = 1; emit(s) }
				continue
			}
			if (c ~ /[-0-9tfn]/) {
				v = ""
				while (i <= n) {
					c = substr(buf, i, 1)
					if (c ~ /[-+0-9.eEtrufalsn]/) { v = v c; i++ } else break
				}
				has[depth] = 1
				emit(v)
				continue
			}
			i++
		}
	}'
}

# json_get JSON PATH -> value of an exact path (first match)
json_get() {
	printf '%s' "$1" | json_flatten | awk -v p="$2" '
		index($0, p "=") == 1 { print substr($0, length(p) + 2); exit }'
}

# json_glob JSON PATTERN -> values of all paths matching a shell-style
# pattern where "*" matches one path segment, e.g. "*.interfaces.*.ifname"
json_glob() {
	local _jre
	_jre=$(printf '%s' "$2" | sed -e 's/[][\.^$+?(){}|]/\\&/g' -e 's/\*/[^.=]*/g')
	printf '%s' "$1" | json_flatten | awk -v re="^${_jre}=" '
		$0 ~ re { s = $0; sub(re, "", s); print s }'
}

# json_keys JSON PREFIX -> immediate child keys below PREFIX ("" = root)
json_keys() {
	printf '%s' "$1" | json_flatten | awk -v p="$2" '
		{
			path = $0; sub(/=.*/, "", path)
			if (p != "") {
				if (index(path, p ".") != 1) next
				path = substr(path, length(p) + 2)
			}
			k = path; sub(/\..*/, "", k)
			if (!(k in seen)) { seen[k] = 1; print k }
		}'
}

# Find array element index whose field equals value:
# json_find_index JSON ARRAYPATH FIELD VALUE
json_find_index() {
	printf '%s' "$1" | json_flatten | awk -v a="$2" -v f="$3" -v v="$4" '
		{
			path = $0; sub(/=.*/, "", path); val = substr($0, length(path) + 2)
			if (index(path, a ".") != 1) next
			rest = substr(path, length(a) + 2)
			i = rest; sub(/\..*/, "", i)
			if (rest == i "." f && val == v) { print i; exit }
		}'
}
