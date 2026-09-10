{ pkgs, coyoteLib }:
let
  reference = {
    checkpoint = ./fixtures/coyote-d0e293-a2ea6a76.patch;
    staticCheckpoint = ./fixtures/coyote-d0e293-a2ea6a76.patch;
    checkpointSha256 = builtins.hashFile "sha256" reference.checkpoint;
    staticCheckpointSha256 = reference.checkpointSha256;
  };
  accepts =
    board: subdivisionReference:
    (builtins.tryEval (
      (coyoteLib.mkCoyoteShellPackage {
        inherit pkgs board subdivisionReference;
        tools = coyoteLib.mkTools {
          inherit pkgs;
          coyoteRoot = ../.;
          xilinxShareRoot = "/nonexistent/xilinx";
        };
        coyoteRoot = ../.;
        hwSource = ../.;
        pname = "subdivision-reference-api-check";
        xilinxVersion = "2023.2";
        xilinxShareRoot = "/nonexistent/xilinx";
      }).drvPath
    )).success;
in
assert accepts "u280" reference;
assert !accepts "v80" reference;
assert !accepts "u280" (removeAttrs reference [ "staticCheckpoint" ]);
assert !accepts "u280" (reference // { checkpointSha256 = "invalid"; });
pkgs.runCommand "subdivision-reference-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${../.}/tests/test_subdivision_reference.py
  touch "$out"
''
