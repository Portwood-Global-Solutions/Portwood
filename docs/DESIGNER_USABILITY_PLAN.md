# Designer usability overhaul

Optimize for a business user editing an existing document. The page is the main workspace; tools appear in one predictable place. Keep the established Portwood navy and teal interface and remove competing overlays.

## Design decisions

- Palette: ink #183452, action #285e63, paper #ffffff, desk #e9eef2, rule #d4dde5, secondary text #536576. Error colour is reserved for a failed action.
- Typography: the Salesforce/system sans-serif for controls at 13px; the document keeps its own fonts and sizes. Use short labels and normal sentence case.
- Layout: a compact document header, one steady formatting toolbar, a large scrollable sheet and a 320px side panel. Align controls and copy left. Use at least 32px controls, with larger primary and destructive targets.
- Primary actions: Insert, Fields, Page, Preview and Save. Authoring is not a numbered sequence. Settings, source and version history stay in the document menu.
- A selected paragraph, image or whole table gets stable Arrange controls in the side panel. Hovering no longer reveals/disappears a competing set of tiny controls over editable text.
- Basic insert choices and connected fields come first. Repeating sections, conditions, chart syntax and detailed query configuration remain available through labelled disclosure controls.
- Routine saves/inserts update a quiet status line. Advisory PDF differences are available in a review panel. Failures remain visible inline, preserve edits and explain recovery.
- Support flowing content and explicit absolute placement. Use native PDF output to verify physical coordinates and pagination.

## Interaction contract

Selection survives moving to any toolbar or panel. Block inserts split a paragraph at the insertion point instead of nesting invalid HTML. Moving or duplicating a whole table preserves its cells, tags and stylesheet. Paired repeat/condition boundaries move as a unit. All mutations enter the same undo history. Saving twice and reopening preserves the complete source shell and CSS.

## Verification matrix

Exercise real browser paths on a separate inactive scratch-org clone: open/reopen; text selection; bold/italic/underline, size, family and colour; field insert at cursor; insert heading/paragraph/table/image; move paragraph and table both ways; duplicate/delete/undo/redo; rows/columns/merge/split; page size/margins; fixed placement; headers/footers; save/reload twice; native PDF generation and regeneration; settings/version/source back paths; keyboard focus/Escape; narrow viewport. Record pass/fail and any unverified path explicitly.
