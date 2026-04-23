# koreader-plugin-wattpad [WIP]

KOReader plugin to download Wattpad stories as EPUB on a jailbroken Kindle.
this is stil wip so expect bugs or error

## Plugin Layout

- wattpad.koplugin/_meta.lua
- wattpad.koplugin/main.lua
- wattpad.koplugin/api.lua
- wattpad.koplugin/ui.lua

## Install On Kindle

1. Copy the folder wattpad.koplugin into your KOReader plugins directory on the Kindle.
2. Final path should look like: koreader/plugins/wattpad.koplugin/
3. Restart KOReader.

## Usage

1. Open KOReader Tools menu.
2. Tap Wattpad.
3. Optional: tap Login to authenticate for library/private stories.
4. Tap Download from URL.
5. Paste a Wattpad story URL containing /story/<id>.
6. Choose chapters (all or selected).
7. The plugin builds an EPUB in /tmp/ and attempts to open it in KOReader.

## Notes

- Story ID parsing uses: url:match("/story/(%d+)").
- EPUB creation is delegated to KOReader builtin backend:
	plugins/newsdownloader.koplugin/epubdownloadbackend.lua
- API networking is in wattpad.koplugin/api.lua and can be tested independently from UI.

