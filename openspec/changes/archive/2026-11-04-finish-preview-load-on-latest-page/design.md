## Context

`isLoaded` decides whether an edit goes in place (`canLiveUpdate` in `updateNSView`) or through a full load. `beginLoading` clears it, `didCommit` clears it, and `didFinish` sets it.

A full load prepares its HTML off the main thread before it navigates. `WebDocumentLoader.currentNavigation` is `nil` during that time and holds the load's navigation afterwards. Nothing stopped the older page's `didFinish` from arriving during that time, or before the new page commits, and setting `isLoaded` for a page about to go.

`refuse-stale-task-toggles` made the consequence worse: `didCommit` labels the latest navigation's page with the newest revision, whatever text that page was prepared from. Its design lists this race under Risks.

## Decisions

### A load is awaited, rather than `didFinish` comparing navigations

The obvious guard is `guard navigation === documentLoader.currentNavigation else { return }`. It closes the race, and it stops the preview working after a Reload. The web view's default context menu has a Reload, which `PreviewWebView` leaves in place and `PreviewLinkRouter` allows. Its navigation comes from WebKit and is never `currentNavigation`, so `didCommit` would clear `isLoaded` and `didFinish` would never set it again. The page would have no typography, and search and scrolling would wait for a load that is not coming. `testAReloadNoLoadStartedStillFinishes` fails with that guard.

So the coordinator keeps `isAwaitingCommit`, true from `beginLoading` until `currentNavigation` commits, and `didFinish` does nothing while it is set. With no load on its way, any page finishes as before, and that covers the Reload.

The wait ends at the commit and not at the finish. A committed load has replaced the older page, so no older page is left to finish. Waiting for the finish would add a hole: a Reload between the commit and the finish, which can be a long time on a page of slow images, cancels the finish the wait depends on and is then ignored itself.

*Alternatives considered:*
- `hasContentInFlight`, which already exists, in place of a new flag. It is also set by a live update and stays set when a live update throws, so a Reload in that state would be ignored.
- Removing Reload from the context menu. It would make the plain comparison safe, but it takes a menu item away to simplify a check.

### `isLoaded` keeps its other rules

`didCommit` still clears `isLoaded` for any navigation, because a committed page has not finished, whichever load it belongs to. An edit in the window takes the full-load path that `updateNSView` already has, and that load supersedes the one on its way. Neither needs a change.

### Hold a real load at its policy decision

The race depends on a load staying unfinished for as long as a test needs. `NavigationGate` stands in front of the coordinator as the navigation delegate and keeps each policy decision until the test opens it. The load is real and the view update is real, so without the fix the older text really does land, labelled as current. The test then sees what the user would, with no timing in it.

The case with `currentNavigation` still `nil` needs no gate to hold it: `load` cannot resume before the test yields the main actor, so one synchronous block sits inside that window.

## Risks / Trade-offs

- **A Reload before the load commits does not end the wait.** The load is what the preview is waiting for, and its page replaces whatever the Reload brought. `PreviewLinkRouter` cancels the Reload outright once the load has its own page URL.
- **A load that fails leaves the wait open.** `isLoaded` was already false in that case, and the next edit starts a new load. Only a Reload after such a failure is affected, and it recovers on the next edit too.
- **Typing during a slow load keeps replacing it.** Each edit in the window starts a load, as it did whenever no stale `didFinish` happened to arrive. The page that commits is always the newest one, and it finishes once the typing stops.
