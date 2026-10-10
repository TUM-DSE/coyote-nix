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
  checked =
    if
      !builtins.isAttrs hints
      || !(builtins.elem (builtins.attrNames hints) [
        [ "groups" ]
        [
          "groups"
          "requirePlacement"
        ]
      ])
    then
      fail "must contain groups and optionally requirePlacement"
    else if !builtins.isBool (hints.requirePlacement or false) then
      fail "requirePlacement must be a Boolean"
    else if !builtins.isList hints.groups || hints.groups == [ ] then
      fail "groups must be a nonempty list"
    else
      let
        groups = map (
          group:
          if
            !builtins.isAttrs group
            ||
              builtins.attrNames group != [
                "cells"
                "name"
                "sites"
              ]
          then
            fail "groups require exactly name, cells, and sites"
          else if !isToken group.name then
            fail "group names must be simple identifiers"
          else if !builtins.isList group.cells || group.cells == [ ] || !builtins.all isCell group.cells then
            fail "cell selectors must be nonempty exact hierarchical names"
          else if group.cells != lib.unique group.cells then
            fail "cell selectors must not repeat within a group"
          else if !builtins.isList group.sites || group.sites == [ ] || !builtins.all isSite group.sites then
            fail "site selectors must be nonempty exact site names"
          else if group.sites != lib.unique group.sites then
            fail "site selectors must not repeat within a group"
          else
            { inherit (group) name cells sites; }
        ) hints.groups;
        names = map (group: group.name) groups;
        cells = lib.concatMap (group: group.cells) groups;
        cellPairsOverlap = builtins.any (
          i:
          builtins.any (
            j:
            i < j
            && (
              let
                left = builtins.elemAt cells i;
                right = builtins.elemAt cells j;
              in
              lib.hasPrefix "${right}/" left || lib.hasPrefix "${left}/" right
            )
          ) (lib.range 0 (builtins.length cells - 1))
        ) (lib.range 0 (builtins.length cells - 1));
        sites = lib.concatMap (group: group.sites) groups;
        normalized = {
          api =
            if hints.requirePlacement or false then
              "coyote-nix.placement-hints/v2"
            else
              "coyote-nix.placement-hints/v1";
          inherit groups;
        }
        // lib.optionalAttrs (hints.requirePlacement or false) { requirePlacement = true; };
      in
      if names != lib.unique names then
        fail "group names must be unique"
      else if cellPairsOverlap then
        fail "cell membership must be hierarchically disjoint across groups"
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
