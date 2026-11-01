# Location Simulator

A simple location simulator for iPhone, installed with **TrollStore**.
Drag the map, tap ▶, and your iPhone reports that position. Save the places you use often and switch between them with one tap.

Based on the LocSim part of [Geranium](https://github.com/c22dev/Geranium) by c22dev (GPL-3.0). Everything except location simulation has been removed.

## Download

**[LocationSimulator.tipa](../../releases/latest/download/LocationSimulator.tipa)** (always the latest build)

Open the file with TrollStore to install. Requires TrollStore on iOS 15 or later.

## Features

- **Map**: fixed centre pin, live coordinates, vertical zoom slider that keeps the pin in place
- **▶ Simulate** the pin position; **⏹ Stop** pops out while simulating. Tap ▶ again to jump to a new spot
- **Enter coordinates** (keyboard button, top right)
- **Bookmarks** with lists (folders): a place can be in several lists, favourite places and favourite lists stay on top
- **History** of every simulated location
- Tap the icon on the left of a place to simulate it, press and hold for more options (edit name / coordinates / lists, add to favourites, delete…)
- Search by the start of words, sort A→Z, Z→A, newest or oldest
- **Export / import** as a plain text file or copied text, so you can move your places to another phone
- Settings: English / Vietnamese, text size, altitude, app icon (built-in or your own photo) and app name

## Text format

One place per line:

```
Name | Latitude, Longitude | Time | List 1; List 2 | ★
```

Only the coordinates are required; lines starting with `#` are ignored.

## Building

The GitHub Actions workflow builds `LocationSimulator.tipa` on every push and publishes it as the latest release. To build locally on a Mac you need Xcode, [Theos](https://theos.dev) and `ldid`, then run `./ipabuild.sh`.

## License

GPL-3.0, see [LICENSE.md](LICENSE.md).
