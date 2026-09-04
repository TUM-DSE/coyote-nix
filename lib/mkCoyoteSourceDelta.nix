{
  pkgs,
  baseSource,
  candidateSource,
  patch,
  baseSourceId,
  candidateSourceId,
  patchSha256,
  changedPaths,
  policy,
  baseRevision ? if builtins.isAttrs baseSource then baseSource.rev or null else null,
  candidateRevision ? if builtins.isAttrs candidateSource then candidateSource.rev or null else null,
  pname ? "coyote-source-delta",
}:

let
  lib = pkgs.lib;
  normalizeSource = value: if builtins.isAttrs value && value ? outPath then value.outPath else value;
  basePath = normalizeSource baseSource;
  candidatePath = normalizeSource candidateSource;
  rawPatchPath = normalizeSource patch;
  immutablePathString = value: builtins.unsafeDiscardStringContext (toString value);
  declaredRevision = value: if builtins.isAttrs value then value.rev or null else null;
  declaredBaseRevision = declaredRevision baseSource;
  declaredCandidateRevision = declaredRevision candidateSource;
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
  patchPath =
    if builtins.isPath rawPatchPath then
      builtins.path {
        path = rawPatchPath;
        name = "${pname}.patch";
      }
    else
      rawPatchPath;
  isSha256 = value: builtins.isString value && builtins.match "[0-9a-f]{64}" value != null;
  isRevision = value: builtins.isString value && builtins.match "[0-9a-f]{40}" value != null;
  canonicalChangedPaths =
    if builtins.isList changedPaths then lib.sort builtins.lessThan changedPaths else [ ];
  policyContract =
    if policy == "user-project-generation" then
      {
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
      }
    else
      throw "coyote-nix: unsupported Coyote source-delta policy: ${toString policy}";
  policyId = builtins.hashString "sha256" (builtins.toJSON policyContract);
  contract = {
    schemaVersion = 1;
    api = "coyote-nix.coyote-source-delta-contract/v1";
    inherit policyId;
    base = {
      sourceId = baseSourceId;
      revision = baseRevision;
    };
    candidate = {
      sourceId = candidateSourceId;
      revision = candidateRevision;
    };
    patch = {
      sha256 = patchSha256;
      changedPaths = canonicalChangedPaths;
    };
  };
  contractId = builtins.hashString "sha256" (builtins.toJSON contract);
  tool = builtins.path {
    path = ../nix/tools/coyote-source-delta.py;
    name = "coyote-source-delta.py";
  };
  checked =
    if !isImmutablePath basePath then
      throw "coyote-nix: Coyote source-delta baseSource must resolve to an immutable Nix path"
    else if !isImmutablePath candidatePath then
      throw "coyote-nix: Coyote source-delta candidateSource must resolve to an immutable Nix path"
    else if !isImmutablePath patchPath then
      throw "coyote-nix: Coyote source-delta patch must resolve to an immutable Nix path"
    else if !isSha256 baseSourceId then
      throw "coyote-nix: Coyote source-delta baseSourceId must be a lowercase SHA-256 digest"
    else if baseSourceId != builtins.hashString "sha256" (immutablePathString basePath) then
      throw "coyote-nix: Coyote source-delta base source ID does not match baseSource"
    else if !isSha256 candidateSourceId then
      throw "coyote-nix: Coyote source-delta candidateSourceId must be a lowercase SHA-256 digest"
    else if candidateSourceId != builtins.hashString "sha256" (immutablePathString candidatePath) then
      throw "coyote-nix: Coyote source-delta candidate source ID does not match candidateSource"
    else if !isSha256 patchSha256 then
      throw "coyote-nix: Coyote source-delta patchSha256 must be a lowercase SHA-256 digest"
    else if patchSha256 != builtins.hashFile "sha256" patchPath then
      throw "coyote-nix: Coyote source-delta patch hash does not match patchSha256"
    else if !isRevision baseRevision then
      throw "coyote-nix: Coyote source-delta baseRevision must be an exact lowercase Git revision"
    else if declaredBaseRevision != null && baseRevision != declaredBaseRevision then
      throw "coyote-nix: Coyote source-delta baseRevision does not match baseSource.rev"
    else if !isRevision candidateRevision then
      throw "coyote-nix: Coyote source-delta candidateRevision must be an exact lowercase Git revision"
    else if declaredCandidateRevision != null && candidateRevision != declaredCandidateRevision then
      throw "coyote-nix: Coyote source-delta candidateRevision does not match candidateSource.rev"
    else if baseSourceId == candidateSourceId || baseRevision == candidateRevision then
      throw "coyote-nix: Coyote source-delta base and candidate sources/revisions must differ"
    else if !builtins.isList changedPaths || changedPaths == [ ] then
      throw "coyote-nix: Coyote source-delta changedPaths must be a nonempty list"
    else if canonicalChangedPaths != changedPaths || lib.unique changedPaths != changedPaths then
      throw "coyote-nix: Coyote source-delta changedPaths must be unique and bytewise sorted"
    else if
      !builtins.all (
        path: builtins.isString path && builtins.match "[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*" path != null
      ) changedPaths
    then
      throw "coyote-nix: Coyote source-delta changedPaths contain a non-canonical path"
    else
      true;
  commonArguments = lib.concatStringsSep " " (
    [
      "--base-source ${lib.escapeShellArg (toString basePath)}"
      "--candidate-source ${lib.escapeShellArg (toString candidatePath)}"
      "--patch ${lib.escapeShellArg (toString patchPath)}"
      "--base-source-id ${lib.escapeShellArg baseSourceId}"
      "--candidate-source-id ${lib.escapeShellArg candidateSourceId}"
      "--base-revision ${lib.escapeShellArg baseRevision}"
      "--candidate-revision ${lib.escapeShellArg candidateRevision}"
      "--patch-sha256 ${lib.escapeShellArg patchSha256}"
      "--policy ${lib.escapeShellArg policy}"
      "--policy-id ${lib.escapeShellArg policyId}"
      "--delta-contract-id ${lib.escapeShellArg contractId}"
    ]
    ++ map (path: "--changed-path ${lib.escapeShellArg path}") canonicalChangedPaths
  );
  proof =
    assert checked;
    pkgs.runCommand pname
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.python3
        ];
        COYOTE_SOURCE_DELTA_BASE = basePath;
        COYOTE_SOURCE_DELTA_CANDIDATE = candidatePath;
        COYOTE_SOURCE_DELTA_PATCH = patchPath;
        passthru.coyoteSourceDelta = {
          schemaVersion = 1;
          api = "coyote-nix.coyote-source-delta/v1";
          kind = "verified-coyote-source-delta";
          failClosed = true;
          inherit
            policy
            policyId
            contractId
            ;
          base = {
            source = toString basePath;
            sourceId = baseSourceId;
            revision = baseRevision;
          };
          candidate = {
            source = toString candidatePath;
            sourceId = candidateSourceId;
            revision = candidateRevision;
          };
          patch = {
            path = toString patchPath;
            sha256 = patchSha256;
            changedPaths = canonicalChangedPaths;
          };
          source = "${proof}/source";
          effectiveSourceId = builtins.hashString "sha256" (
            builtins.unsafeDiscardStringContext "${proof}/source"
          );
          metadata = "metadata/delta.json";
          completion = "metadata/complete.json";
          verificationTool = toString tool;
        };
      }
      ''
        python3 ${tool} apply ${commonArguments} --output "$out"
      '';
in
proof
