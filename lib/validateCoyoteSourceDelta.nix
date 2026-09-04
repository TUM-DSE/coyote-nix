{
  pkgs,
  baseSource,
  sourceDelta,
}:

let
  lib = pkgs.lib;
  basePath =
    if builtins.isAttrs baseSource && baseSource ? outPath then baseSource.outPath else baseSource;
  isSha256 = value: builtins.isString value && builtins.match "[0-9a-f]{64}" value != null;
  isRevision = value: builtins.isString value && builtins.match "[0-9a-f]{40}" value != null;
  isCanonicalRelativePath =
    value:
    builtins.isString value && builtins.match "[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*" value != null;
  immutablePathString = value: builtins.unsafeDiscardStringContext (toString value);
  isImmutablePath =
    value:
    builtins.isPath value
    || (
      builtins.isString value
      && (
        let
          context = builtins.getContext value;
          key = immutablePathString value;
        in
        builtins.attrNames context == [ key ] && (context.${key}.path or false)
      )
    );
  delta =
    if !lib.isDerivation sourceDelta then
      throw "coyote-nix: userProjectCoyoteSource must be a verified Coyote source-delta derivation"
    else if !(sourceDelta ? coyoteSourceDelta) then
      throw "coyote-nix: userProjectCoyoteSource lacks the verified source-delta contract"
    else
      sourceDelta.coyoteSourceDelta;
  requiredAttributes = [
    "api"
    "base"
    "candidate"
    "completion"
    "contractId"
    "effectiveSourceId"
    "failClosed"
    "kind"
    "metadata"
    "patch"
    "policy"
    "policyId"
    "schemaVersion"
    "source"
    "verificationTool"
  ];
  policyContract = {
    schemaVersion = 1;
    api = "coyote-nix.coyote-source-delta-policy/v1";
    name = "user-project-generation";
    allowedPrefixes = [
      "scripts/cr_prjcts/"
      "tests/user_project_source_management/"
    ];
    allowAdditions = true;
    allowDeletions = false;
    allowModeChanges = false;
  };
  expectedPolicyId = builtins.hashString "sha256" (builtins.toJSON policyContract);
  verificationTool = builtins.path {
    path = ../nix/tools/coyote-source-delta.py;
    name = "coyote-source-delta.py";
  };
  expectedContract = {
    schemaVersion = 1;
    api = "coyote-nix.coyote-source-delta-contract/v1";
    policyId = delta.policyId;
    base = {
      sourceId = delta.base.sourceId;
      revision = delta.base.revision;
    };
    candidate = {
      sourceId = delta.candidate.sourceId;
      revision = delta.candidate.revision;
    };
    patch = {
      sha256 = delta.patch.sha256;
      changedPaths = delta.patch.changedPaths;
    };
  };
  checked =
    if !isImmutablePath basePath then
      throw "coyote-nix: base Coyote source must resolve to an immutable Nix path"
    else if builtins.attrNames delta != requiredAttributes then
      throw "coyote-nix: userProjectCoyoteSource has an unrecognized source-delta contract"
    else if
      builtins.attrNames delta.base != [
        "revision"
        "source"
        "sourceId"
      ]
      ||
        builtins.attrNames delta.candidate != [
          "revision"
          "source"
          "sourceId"
        ]
      ||
        builtins.attrNames delta.patch != [
          "changedPaths"
          "path"
          "sha256"
        ]
    then
      throw "coyote-nix: userProjectCoyoteSource has malformed nested source-delta contracts"
    else if
      delta.schemaVersion != 1
      || delta.api != "coyote-nix.coyote-source-delta/v1"
      || delta.kind != "verified-coyote-source-delta"
      || delta.failClosed != true
    then
      throw "coyote-nix: userProjectCoyoteSource has an incompatible source-delta API"
    else if delta.policy != "user-project-generation" || delta.policyId != expectedPolicyId then
      throw "coyote-nix: userProjectCoyoteSource does not satisfy the user-project-generation policy"
    else if !isSha256 delta.base.sourceId || !isRevision delta.base.revision then
      throw "coyote-nix: userProjectCoyoteSource has malformed base identities"
    else if !isSha256 delta.candidate.sourceId || !isRevision delta.candidate.revision then
      throw "coyote-nix: userProjectCoyoteSource has malformed candidate identities"
    else if
      delta.base.sourceId == delta.candidate.sourceId || delta.base.revision == delta.candidate.revision
    then
      throw "coyote-nix: userProjectCoyoteSource base and candidate sources/revisions must differ"
    else if
      !builtins.isList delta.patch.changedPaths
      || delta.patch.changedPaths == [ ]
      || delta.patch.changedPaths != lib.sort builtins.lessThan delta.patch.changedPaths
      || delta.patch.changedPaths != lib.unique delta.patch.changedPaths
      || !builtins.all isCanonicalRelativePath delta.patch.changedPaths
      || !builtins.all (
        path: lib.any (prefix: lib.hasPrefix prefix path) policyContract.allowedPrefixes
      ) delta.patch.changedPaths
    then
      throw "coyote-nix: userProjectCoyoteSource has invalid policy-scoped changed paths"
    else if immutablePathString delta.base.source != immutablePathString basePath then
      throw "coyote-nix: userProjectCoyoteSource base does not match coyoteRoot"
    else if delta.base.sourceId != builtins.hashString "sha256" (immutablePathString basePath) then
      throw "coyote-nix: userProjectCoyoteSource base source ID does not match coyoteRoot"
    else if !isImmutablePath delta.candidate.source || !isImmutablePath delta.patch.path then
      throw "coyote-nix: userProjectCoyoteSource candidate and patch must be immutable Nix paths"
    else if
      delta.candidate.sourceId
      != builtins.hashString "sha256" (immutablePathString delta.candidate.source)
    then
      throw "coyote-nix: userProjectCoyoteSource candidate source ID is invalid"
    else if
      !isSha256 delta.patch.sha256
      || delta.patch.sha256 != builtins.hashFile "sha256" delta.patch.path
      || !isSha256 delta.contractId
    then
      throw "coyote-nix: userProjectCoyoteSource has malformed patch or contract identities"
    else if delta.contractId != builtins.hashString "sha256" (builtins.toJSON expectedContract) then
      throw "coyote-nix: userProjectCoyoteSource delta contract ID is invalid"
    else if immutablePathString delta.source != immutablePathString "${sourceDelta}/source" then
      throw "coyote-nix: userProjectCoyoteSource must expose only its verified proof/source tree"
    else if
      delta.effectiveSourceId != builtins.hashString "sha256" (immutablePathString delta.source)
    then
      throw "coyote-nix: userProjectCoyoteSource effective source ID is invalid"
    else if delta.metadata != "metadata/delta.json" || delta.completion != "metadata/complete.json" then
      throw "coyote-nix: userProjectCoyoteSource metadata layout is incompatible"
    else if immutablePathString delta.verificationTool != immutablePathString verificationTool then
      throw "coyote-nix: userProjectCoyoteSource was not bound to this coyote-nix verifier"
    else
      true;
  verificationArguments = lib.concatStringsSep " " (
    [
      "--base-source ${lib.escapeShellArg delta.base.source}"
      "--candidate-source ${lib.escapeShellArg delta.candidate.source}"
      "--patch ${lib.escapeShellArg delta.patch.path}"
      "--base-source-id ${lib.escapeShellArg delta.base.sourceId}"
      "--candidate-source-id ${lib.escapeShellArg delta.candidate.sourceId}"
      "--base-revision ${lib.escapeShellArg delta.base.revision}"
      "--candidate-revision ${lib.escapeShellArg delta.candidate.revision}"
      "--patch-sha256 ${lib.escapeShellArg delta.patch.sha256}"
      "--policy ${lib.escapeShellArg delta.policy}"
      "--policy-id ${lib.escapeShellArg delta.policyId}"
      "--delta-contract-id ${lib.escapeShellArg delta.contractId}"
    ]
    ++ map (path: "--changed-path ${lib.escapeShellArg path}") delta.patch.changedPaths
  );
  verificationCommand = ''
    ${pkgs.python3}/bin/python ${verificationTool} verify \
      ${verificationArguments} --proof ${lib.escapeShellArg (toString sourceDelta)}
  '';
in
assert checked;
delta
// {
  proof = sourceDelta;
  inherit verificationCommand;
}
