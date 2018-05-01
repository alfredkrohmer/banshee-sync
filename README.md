# Banshee Music and Playlist Sync script

This script uses the SQLite database of Banshee to sync your music collection and playlists to a target device (e.g. a mobile phone attached via MTP). *Banshee must not be running while you use this script.*

## Requirements

* Ruby installation, latest is greatest
* `bundler` gem installed (`gem install bundler`)

## Setup

Install dependencies:

```bash
$ bundle
```

## Usage

Copy `config.yaml.example` to `config.yaml`, adapt it to your device specifics and run:

```bash
$ ruby banshee-sync.rb config.yaml
```

The script will look through your music collection and will only start logging something once it starts copying / transcoding, so go grab a coffee if you have a rather large collection.
