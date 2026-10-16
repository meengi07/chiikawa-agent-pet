from pathlib import Path

repo_root = Path(defines["repo_root"])
app = str(repo_root / "build" / "ChiikawaPet.app")

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = str(repo_root / "build/ChiikawaPet.app/Contents/Resources/AppIcon.icns")
background = str(repo_root / "build/macos-artwork/dmg-background.tiff")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
# Reserve window chrome around the 720 × 480 artwork, including Finder's path bar.
window_rect = ((160, 160), (720, 540))
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
show_icon_preview = False
show_item_info = False
label_pos = "bottom"
text_size = 13
icon_size = 112
# Icon centers use logical points from the content area's top-left corner.
icon_locations = {
    "ChiikawaPet.app": (190, 238),
    "Applications": (530, 238),
}
