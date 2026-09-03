{
  coyoteRoot,
  coyoteRevision ? null,
}:

let
  inferredRevision = if builtins.isAttrs coyoteRoot && coyoteRoot ? rev then coyoteRoot.rev else null;
  revision = if coyoteRevision != null then coyoteRevision else inferredRevision;
  validRevision =
    builtins.isString revision
    && (
      builtins.match "[0-9a-fA-F]{40}" revision != null
      || builtins.match "[0-9a-fA-F]{64}" revision != null
    );
in
if revision == null then
  null
else if validRevision then
  revision
else
  throw "coyote-nix: Coyote source revision must be a full 40- or 64-character Git object ID"
