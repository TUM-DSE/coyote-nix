{ pkgs, hints }:

let
  lib = pkgs.lib;
  fail = message: throw "coyote-nix: placementHints ${message}";
  isToken =
    value: builtins.isString value && builtins.match "[A-Za-z][A-Za-z0-9_]{0,47}" value != null;
  isCell =
    value: builtins.isString value && value != "" && builtins.match ".*[[:cntrl:]].*" value == null;
  isSite =
    value: builtins.isString value && builtins.match "[A-Z][A-Z0-9_]*_X[0-9]+Y[0-9]+" value != null;
  below = child: parent: child == parent || lib.hasPrefix "${parent}/" child;
  pairwise =
    predicate: values:
    builtins.any (
      i:
      builtins.any (j: i < j && predicate (builtins.elemAt values i) (builtins.elemAt values j)) (
        lib.range 0 (builtins.length values - 1)
      )
    ) (lib.range 0 (builtins.length values - 1));
  overlap = left: right: below left right || below right left;
  checked =
    if
      !builtins.isAttrs hints
      || !(hints ? groups)
      || builtins.any (
        name:
        !(builtins.elem name [
          "groups"
          "requirePlacement"
          "allowUnplacedStatic"
        ])
      ) (builtins.attrNames hints)
    then
      fail "must contain groups and only supported placement options"
    else if !builtins.isBool (hints.requirePlacement or false) then
      fail "requirePlacement must be a Boolean"
    else if !builtins.isBool (hints.allowUnplacedStatic or false) then
      fail "allowUnplacedStatic must be a Boolean"
    else if !builtins.isList hints.groups || hints.groups == [ ] then
      fail "groups must be a nonempty list"
    else
      let
        groups = map (
          group:
          if
            !builtins.isAttrs group
            || !(builtins.elem (builtins.attrNames group) [
              [
                "cells"
                "name"
                "sites"
              ]
              [
                "cells"
                "excludeCells"
                "name"
                "sites"
              ]
            ])
          then
            fail "groups require name, cells, sites and optional excludeCells"
          else if !isToken group.name then
            fail "group names must be simple identifiers"
          else if !builtins.isList group.cells || group.cells == [ ] || !builtins.all isCell group.cells then
            fail "cell selectors must be nonempty exact hierarchical names"
          else if pairwise overlap group.cells then
            fail "cell selectors must be unique and disjoint within a group"
          else if
            !builtins.isList (group.excludeCells or [ ]) || !builtins.all isCell (group.excludeCells or [ ])
          then
            fail "excludeCells must contain exact hierarchical names"
          else if pairwise overlap (group.excludeCells or [ ]) then
            fail "exclusions must be unique and disjoint"
          else if
            builtins.any (excluded: !builtins.any (cell: lib.hasPrefix "${cell}/" excluded) group.cells) (
              group.excludeCells or [ ]
            )
          then
            fail "exclusions must be strict descendants of selected cells"
          else if !builtins.isList group.sites || group.sites == [ ] || !builtins.all isSite group.sites then
            fail "site selectors must be nonempty exact site names"
          else if group.sites != lib.unique group.sites then
            fail "site selectors must not repeat within a group"
          else
            {
              inherit (group) name cells sites;
            }
            // lib.optionalAttrs ((group.excludeCells or [ ]) != [ ]) {
              inherit (group) excludeCells;
            }
        ) hints.groups;
        names = map (group: group.name) groups;
        selections = lib.concatMap (
          group:
          map (name: {
            inherit name;
            excluded = group.excludeCells or [ ];
          }) group.cells
        ) groups;
        excludedBy = selection: name: builtins.any (excluded: below name excluded) selection.excluded;
        selectedOverlap =
          left: right:
          left.name == right.name
          || (below left.name right.name && !(excludedBy right left.name))
          || (below right.name left.name && !(excludedBy left right.name));
        sites = lib.concatMap (group: group.sites) groups;
        hasExclusions = builtins.any (group: group ? excludeCells) groups;
        normalized = {
          api =
            if hasExclusions then
              "coyote-nix.placement-hints/v4"
            else if hints.allowUnplacedStatic or false then
              "coyote-nix.placement-hints/v3"
            else if hints.requirePlacement or false then
              "coyote-nix.placement-hints/v2"
            else
              "coyote-nix.placement-hints/v1";
          inherit groups;
        }
        // lib.optionalAttrs (hints.requirePlacement or false) { requirePlacement = true; }
        // lib.optionalAttrs (hasExclusions || (hints.allowUnplacedStatic or false)) {
          allowUnplacedStatic = hints.allowUnplacedStatic or false;
          requirePlacement = hints.requirePlacement or false;
        };
      in
      if names != lib.unique names then
        fail "group names must be unique"
      else if pairwise selectedOverlap selections then
        fail "cell membership must be disjoint after explicit exclusions"
      else if sites != lib.unique sites then
        fail "site membership must be disjoint across groups"
      else
        normalized;
  json = builtins.toJSON checked;
  id = builtins.hashString "sha256" json;
in
{
  inherit checked id json;
  manifest = pkgs.writeText "placement-hints-${id}.json" json;
}
