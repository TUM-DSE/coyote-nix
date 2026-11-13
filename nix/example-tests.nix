# The pieces test-examples builds, keyed <board>/<example>/<piece>: each
# example's host program (sw) and its shell and application (shell, app) or
# one-piece image (hw), as far as the example has them.
{ lib, examples }:
lib.listToAttrs (
  lib.concatLists (
    lib.mapAttrsToList (
      board: boardExamples:
      lib.concatLists (
        lib.mapAttrsToList (
          name: example:
          map (piece: lib.nameValuePair "${board}/${name}/${piece}" example.${piece}) (
            lib.filter (piece: example ? ${piece}) [
              "sw"
              "shell"
              "app"
              "hw"
            ]
          )
        ) (removeAttrs boardExamples [ "shells" ])
      )
    ) examples
  )
)
