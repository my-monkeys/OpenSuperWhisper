# dmgbuild settings for the release disk image: the app, a link to Applications, and a window
# laid out so the arrow in the background points from one to the other.
#   dmgbuild -s Scripts/dmg/settings.py -D app=<path to .app> -D background=Scripts/dmg/background.png <volume> <out.dmg>
# dmgbuild picks up background@2x.png next to background.png for Retina screens.
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
hide_extensions = [appname]

background = defines["background"]
# 420 points tall: the picture is 400, and the toolbar Finder shows anyway takes its share.
window_rect = ((200, 160), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Icon centres, matching the arrow in background.html.
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 160), "Applications": (470, 160)}
