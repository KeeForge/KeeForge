# SiteMatching test fixtures

Both files come from independent projects, so the package's answers are checked against vectors it did not write.

| File | Source | License |
| --- | --- | --- |
| `test_psl.txt` | [publicsuffix/list](https://github.com/publicsuffix/list) `tests/test_psl.txt` at commit `6ca11f5dd03631be45cc04049fd23a5b0c44c0ac`, unmodified | Public domain (CC0), per its header |
| `whatwg-url-hosts.json` | [web-platform-tests](https://github.com/web-platform-tests/wpt) `url/resources/urltestdata.json` at commit `8c17bfeb3e66a2986be16b0e004f85ace68db647`, selected as below | BSD 3-Clause (web-platform-tests) |

`whatwg-url-hosts.json` keeps the test cases whose `input` starts with `http://` or `https://` (case-insensitive), because `SiteHost` reads absolute URLs and ignores a base URL:

- `hosts`: cases WHATWG parses with an `http:` or `https:` protocol, as `{input, hostname}`. 167 cases.
- `failures`: inputs WHATWG rejects (`"failure": true`) that are not also in `hosts`. 190 inputs.

Duplicates keep their first occurrence, in source order. The JSON is ASCII with `\u` escapes, so control characters and invisible code points stay visible in review.

To refresh, download both upstream files, rebuild the selection the same way, and review every change to the divergence lists in `PublicSuffixListVectorTests` and `WHATWGHostVectorTests`. Update the commits above.
