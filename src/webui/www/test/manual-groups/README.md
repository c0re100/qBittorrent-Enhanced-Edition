# Manual transfer groups

Select torrents with Ctrl/Cmd or Shift, choose **Group…**, and enter a name.
Choose a parent group to create or join a subgroup; the same name under a
different parent is a separate group. Entering an existing name under the same
parent adds the selected torrents to that group. Membership
does not depend on save paths. **Remove from group** affects the selection;
**Manage** on a group header changes its name or parent, moving the whole
subtree. Choose **Top level** to move it out. A group cannot be moved into itself
or its descendants. Dissolving removes only that level: direct torrents and
child groups move up to the parent, and deeper structure is retained.

Groups start collapsed and expand independently at each level. Expand a group
to select individual torrents for normal
torrent actions. Collapsing clears hidden selections. Group headers are display
rows, never torrent IDs. Filtering happens before grouping, so counts, size,
weighted progress and speeds summarize matching members only. Sorting places a
group at its first matching member and preserves the member sort order.

Membership uses the existing authenticated clientdata API, one
`qbt_manual_group_<torrent hash>` key per torrent. A top-level name remains a
string, preserving existing groups (including literal slashes in names). Nested
memberships are arrays of path segments; ancestors are derived from those paths.
No automatic rewrite of existing data occurs. Writes update the selection or
whole moved subtree in one atomic clientdata store request. Group paths have a
maximum depth of 32. Empty groups disappear when they have no descendant tasks.
An unsuccessful write leaves local membership unchanged. Visible clients
refresh group data every ten seconds. Concurrent edits of different torrents do
not overwrite each other; concurrent edits of the same torrent use last-write
wins. Expansion is local to the page, not shared. Removed torrent keys are not
automatically pruned, so readding the same torrent restores membership. The
existing clientdata size limit applies.

## Validation

Run `npm test` in `src/webui/www`. The added tests cover cross-path grouping,
filtering, sorted expansion, selected-key persistence, failed writes, legacy
names, multilevel moves, merges, promotion on dissolve, cycle rejection and depth
limits.

Browser regression checklist (test with virtual lists both off and on):

1. Select two torrents in different folders, create a named group, expand it.
2. Select a member, collapse the group, then select all. Hidden members and
   headers must not be selected. Right-clicking a header must not select it.
3. Add another torrent by entering the same group name. Reload, then open an
   independent browser context; membership should remain present.
4. Filter to a single member, then clear the filter. Counts should follow it.
5. Rename a group to text containing HTML markup. Render it as plain text.
6. Scroll through the virtual list and back. Expand and manage the group using
   actual pointer input; controls must survive redraws.
7. Reject a clientdata store request (for example HTTP 409). Keep the dialog and
   membership, show the error, then allow a retry.
8. Move a group containing subgroups into another group, then out to the top
   level. Reject self/descendant targets. Merge into an existing sibling group.
9. Dissolve an intermediate group; promote its tasks and child groups one level.
   Verify torrent count, paths, categories and tags remain unchanged.
10. Confirm the Group button is 24px high and vertically aligned with the
    neighboring toolbar icon (tested center-line difference: 0px).

Validated with the 5.2.4.10 backend and a 1,094-torrent session. All 15 unit tests
pass. Chromium automation covers nested groups in normal and virtual lists; the
initial single-level version also received a Windows 360ChromeX manual UI check.
The deployed nested WebUI was exercised with real clientdata writes, reload and
an independent browser context, preserving all 86 existing memberships and all
torrent paths, categories and tags. This is functional regression coverage and
short live observation, not a long-duration soak test. No C++ rebuild is required
for alternative-WebUI validation.

The screenshots below use synthetic fixture torrents, not a user's library.

![Collapsed group](collapsed.png)

![Expanded group](expanded.png)
