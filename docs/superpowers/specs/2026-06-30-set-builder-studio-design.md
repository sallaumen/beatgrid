# Set Builder Studio Design

## Goal

Upgrade the set planner from a fixed small track-count form into a configurable long-set builder that can plan a full party set, including five-hour sessions, without forcing the DJ into one musical direction.

## Product Shape

The set page keeps the current tracklist visible and expands the right-side planner into a compact Planning Studio. The planner supports either duration-based planning or explicit track-count planning. It exposes backend-defined presets so new musical strategies can be adjusted in domain code without rebuilding the LiveView flow.

## Presets

The first version ships six directions:

- `forro_roots_marathon`: roots-focused, excludes MPB and Forro MPB.
- `roots_to_forro_mpb`: starts in Forro Roots, passes through Forro, lands in Forro MPB, excludes pure MPB.
- `roots_to_classic`: starts in Roots and resolves into Classic Forro.
- `forro_orbit`: mostly Forro with controlled nearby Forro styles, excludes pure MPB.
- `mpb_set`: a deliberate MPB set.
- `custom`: uses the set's target style and manual constraints.

## Backend Rules

`Beatgrid.Sets` owns all planning configuration and duration estimation. LiveView only translates form parameters and delegates. Each preset has a target style, excluded folders, max tracks, description, and phased style targets. The existing energy-arc planner still controls section roles and transitions; the new preset layer changes style intent over the arc.

Duration mode estimates track count from the average duration of present tracks that fit the selected preset. If no measured duration exists, it falls back to 3.5 minutes per track. One planning run is capped at 240 tracks.

## Testing

Domain tests cover preset exposure, hard MPB exclusion in Roots Marathon, and phased transition into Forro MPB. LiveView tests cover planning above the old 60-track cap and estimating a five-hour set from track duration.
