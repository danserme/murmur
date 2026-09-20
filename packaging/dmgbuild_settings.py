import os
from pathlib import Path

ROOT = Path(os.environ["MURMUR_ROOT"])
APP = ROOT / "build/DerivedData/Build/Products/Release/murmur.app"

files = [str(APP)]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["murmur.app"]

background = str(ROOT / "packaging/dmg-background.png")
window_rect = ((280, 160), (620, 400))
icon_size = 128
text_size = 12
icon_locations = {
    "murmur.app": (155, 185),
    "Applications": (465, 185),
}

default_view = "icon-view"
include_icon_view_settings = True
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
