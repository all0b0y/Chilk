# dmgbuild settings for Chilk's installer DMG — used by scripts/release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=<Chilk.app> -D background=<dmg-background.png> "Чилк" <out.dmg>
# The background (and its @2x beside it) is drawn by `chilk-render dmg`; its arrow sits between the two icons below.
import os.path

app = defines["app"]  # type: ignore # noqa: F821 — dmgbuild provides `defines`
background = defines["background"]  # type: ignore # noqa: F821

format = "ULFO"  # lzfse: smaller and faster to open than zlib; macOS 10.11+
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 200), "Applications": (490, 200)}

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128
