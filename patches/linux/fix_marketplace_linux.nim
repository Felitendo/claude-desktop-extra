# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim
#
# The Claude Code CLI stores personal plugins as scope="project" with
# projectPath=$HOME. getAllLocalPluginsWithResolver promotes those entries to
# scope="user", so the web UI lists them under "Personal Plugins" instead of
# under the current project header.

import std/[os, strformat, strutils]
import std/nre

const EXPECTED_PATCHES = 1

proc apply*(input: string): string =
  result = input
  var patchesApplied = 0

  # B: scope normalization in getAllLocalPluginsWithResolver
  if result.contains(
    re"""if\([\w$]+\.scope===\"user\"\|\|[\w$]+\.scope===\"project\"\&\&[\w$]+\.projectPath"""
  ):
    echo "  [SKIP] B already patched"
    inc patchesApplied
  else:
    # Try new pattern (v1.8089+): if(X.scope==="user")return this.entryToPluginInfo(A,X,B,C);
    # v1.26832.0 quotes the scope literal with backticks, hence the ["`] class.
    let mNew = result.find(
      re"""if\(([\w$]+)\.scope===["`]user["`]\)return this\.entryToPluginInfo\(([\w$]+),\1,([\w$]+),([\w$]+)\);"""
    )
    # Try old pattern: if(X.scope==="user"){Y.push(this.entryToPluginInfo(A,X,B,C));continue}
    let mOld = result.find(
      re"""if\(([\w$]+)\.scope===["`]user["`]\)\{([\w$]+)\.push\(this\.entryToPluginInfo\(([\w$]+),\1,([\w$]+),([\w$]+)\)\);continue\}"""
    )
    if mNew.isSome:
      let c = mNew.get.captures
      let (e, g, n, b) = (c[0], c[1], c[2], c[3])
      let homedir =
        e & ".scope===\"project\"&&" & e & ".projectPath&&" &
        "process.env.HOME&&require(\"path\").normalize(" & e &
        ".projectPath)===require(\"path\").normalize(process.env.HOME)"
      result =
        result[0 ..< mNew.get.matchBounds.a] & "if(" & e & ".scope===\"user\"||" &
        homedir & ")return this.entryToPluginInfo(" & g & ",{..." & e &
        ",scope:\"user\"}," & n & "," & b & ");" &
        result[mNew.get.matchBounds.b + 1 .. ^1]
      echo "  [OK] B scope normalization (1 match, return-style)"
      inc patchesApplied
    elif mOld.isSome:
      let c = mOld.get.captures
      let (e, s, o, n, i) = (c[0], c[1], c[2], c[3], c[4])
      let homedir =
        e & ".scope===\"project\"&&" & e & ".projectPath&&" &
        "process.env.HOME&&require(\"path\").normalize(" & e &
        ".projectPath)===require(\"path\").normalize(process.env.HOME)"
      result =
        result[0 ..< mOld.get.matchBounds.a] & "if(" & e & ".scope===\"user\"||" &
        homedir & "){" & s & ".push(this.entryToPluginInfo(" & o & ",{..." & e &
        ",scope:\"user\"}," & n & "," & i & "));continue}" &
        result[mOld.get.matchBounds.b + 1 .. ^1]
      echo "  [OK] B scope normalization (1 match, push-style)"
      inc patchesApplied
    else:
      echo "  [FAIL] B scope normalization: 0 matches"

  if patchesApplied < EXPECTED_PATCHES:
    echo &"  [FAIL] Only {patchesApplied}/{EXPECTED_PATCHES} sub-patches applied"
    quit(1)

  let originalDelta = input.count('{') - input.count('}')
  let patchedDelta = result.count('{') - result.count('}')
  if originalDelta != patchedDelta:
    echo &"  [FAIL] Brace balance changed: {originalDelta} -> {patchedDelta}"
    quit(1)

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_marketplace_linux <path_to_index.js>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: fix_marketplace_linux ==="
  echo "  Target: " & filePath
  if not fileExists(filePath):
    echo "  [FAIL] File not found: " & filePath
    quit(1)
  let input = readFile(filePath)
  let output = apply(input)
  if output != input:
    writeFile(filePath, output)
  echo "  [PASS] Marketplace Linux patch applied"
