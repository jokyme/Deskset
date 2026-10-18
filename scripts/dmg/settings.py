"""Finder layout; coordinates match render-background.swift (720 × 460 points)."""
import os

app = os.path.abspath(defines["app"])
app_name = os.path.basename(app)
files = [app, (defines["guide"], "Install and Upgrade.txt")]
symlinks = {"Applications": "/Applications"}
hide = ["Install and Upgrade.txt"]
# Don't set FinderInfo on the signed .app to hide its extension: codesign --strict rejects that metadata.
background = defines["background"]
app_icon = os.path.join(app, "Contents", "Resources", "Deskset.icns")
if os.path.isfile(app_icon):
    icon = app_icon

format = "UDZO"
filesystem = "HFS+"
# Finder's bounds include its 32-point title bar; leave the full 460-point
# background visible underneath it.
window_rect = ((180, 160), (720, 492))
default_view = "icon-view"
icon_locations = {app_name: (190, 225), "Applications": (530, 225)}
icon_size = 112
text_size = 14
grid_spacing = 80
arrange_by = None
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
