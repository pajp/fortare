# Fortare

Fortare is an iOS app that imports outdoor cycling workout routes from Apple Health and renders them as a combined map heat overlay.

## Features

- Imports cycling workout route data from HealthKit.
- Combines all imported routes into a single map overlay.
- Colors route segments by traffic density, from blue for occasional paths to red for the most repeated corridors.
- Supports import windows from today through all time.
- Shows compact route stats, including route count, total distance, days with sessions, and average route distance.

## Requirements

- Xcode 26.4 or newer.
- iOS target with HealthKit support.
- A device or account with cycling workouts that include route samples.

## Notes

Health route data is read locally through HealthKit. Fortare does not include a backend or remote data sync.

## License

MIT. See [LICENSE](LICENSE).
