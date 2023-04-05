var efb = nil;

logprint(3, "EFB main module start");

# Un-grab the keyboard in case it was still grabbed by a previous instance
props.globals.getNode('/instrumentation/efb/keyboard-grabbed', 1).setValue(0);

var systemAppBasedir = acdir ~ '/Nasal/efb/apps';
var customAppBasedir = acdir ~ '/Nasal/efbapps';

globals.efb.availableApps = {};
globals.efb.registerApp_ = func(basedir, key, label, iconName, class) {
    globals.efb.availableApps[key] = {
        basedir: basedir,
        key: key,
        icon: (iconName == nil) ? (acdir ~ '/Models/EFB/icons/unknown-app.png') : (basedir ~ '/' ~ iconName),
        label: label,
        loader: func (g) { return class.new(g); },
    };
};

var registerApp = nil;

include('util.nas');
include('downloadManager.nas');

if (contains(globals.efb, 'downloadManager')) {
    var err = [];
    call(globals.efb.downloadManager.cancelAll, [], globals.efb.downloadManager, {}, err);
    if (size(err)) {
        debug.printerror(err);
    }
}
globals.efb.downloadManager = DownloadManager.new();

var loadAppDir = func (basedir) {
    printf("Scanning for apps in %s", basedir);
    var appFiles = directory(basedir) or [];
    foreach (var f; appFiles) {
        if (substr(f, 0, 1) != '.') {
            printf("Found app: %s", f);
            var dirname = basedir ~ '/' ~ f;
            registerApp = func(key, label, iconName, class) {
                print(dirname);
                registerApp_(dirname, key, label, iconName, class);
            }
            io.load_nasal(dirname ~ '/main.nas', 'efb');
        }
    }
};

loadAppDir(systemAppBasedir);
loadAppDir(customAppBasedir);

var EFB = {
    new: func (master) {
        var m = {
            parents: [EFB],
            master: master,
        };
        m.currentApp = nil;
        m.shellPage = 0;
        m.shellNumPages = 1;
        m.reportedRotation = 0;
        m.apps = [];
        foreach (var k; sort(keys(availableApps), cmp)) {
            var app = availableApps[k];
            append(m.apps,
                { icon: app.icon,
                , label: app.label,
                , loader: app.loader,
                , key: app.key,
                , basedir: app.basedir,
                });
        }
        m.initialize();
        return m;
    },

    setupBackgroundImage: func {
        var backgroundImagePaths = [];

        var appendPathsFromNodes = func (parentNode, selector) {
            if (typeof(parentNode) == 'scalar')
                parentNode = props.globals.getNode(parentNode);
            if (parentNode == nil)
                return;
            var nodes = parentNode.getChildren(selector);
            foreach (var n; nodes) {
                var path = n.getValue();
                if (path != nil) {
                    append(backgroundImagePaths, acdir ~ '/' ~ path);
                }
            }
        }

        me.backgroundImg = me.shellGroup.createChild('image');

        appendPathsFromNodes('/instrumentation/efb', 'background-image');
        if (size(backgroundImagePaths) == 0) {
            # Nothing configured, try previews
            appendPathsFromNodes('/sim/previews', 'preview/path');
        }
        if (size(backgroundImagePaths) == 0) {
            # Nothing suitable found yet, use the default image.
            append(backgroundImagePaths, acdir ~ '/Models/EFB/wallpaper.jpg');
        }
        var index = math.min(size(backgroundImagePaths) - 1, math.floor(rand() * size(backgroundImagePaths)));
        var path = backgroundImagePaths[index];
        me.backgroundImg.set('src', path);
        (var w, var h) = me.backgroundImg.imageSize();
        var minZoomX = 512 / w;
        var minZoomY = 768 / h;
        var zoom = math.max(minZoomX, minZoomY);
        var dx = (512 - w * zoom) * 0.5;
        var dy = (768 - h * zoom) * 0.5;
        me.backgroundImg.setTranslation(dx, dy);
        me.backgroundImg.setScale(zoom, zoom);
    },

    initialize: func() {
        me.shellGroup = me.master.createChild('group');
        me.shellPages = [];
        me.setupBackgroundImage();
        me.background = me.shellGroup.createChild('path')
                            .rect(0, 0, 512, 768)
                            .setColorFill(1, 1, 1, 0.5);

        me.clientGroup = me.master.createChild('group');

        me.overlay = canvas.parsesvg(me.master, acdir ~ "/Models/EFB/overlay.svg", {'font-mapper': font_mapper});
        me.clockElem = me.master.getElementById('clock.digital');
        me.shellNumPages = math.ceil(size(me.apps) / 20);
        for (var i = 0; i < me.shellNumPages; i += 1) {
            var pageGroup = me.shellGroup.createChild('group');
            append(me.shellPages, pageGroup);
        }
        var row = 0;
        var col = 0;
        var page = 0;
        foreach (var app; me.apps) {
            app.row = row;
            app.col = col;
            app.page = page;
            app.app = nil;
            col = col + 1;
            if (col > 3) {
                col = 0;
                row = row + 1;
                if (row > 4) {
                    row = 0;
                    page = page + 1;
                }
            }

            # App icon grid:
            # Each app gets a 128x141 square.
            app.shellIcon = me.shellPages[page].createChild('group');
            app.shellIcon.setTranslation(app.col * 128, app.row * 141 + 64);
            app.box = [
                app.col * 128, app.row * 141 + 64,
                app.col * 128 + 128, app.row * 141 + 64 + 86,
            ];
            var img = app.shellIcon.createChild('image');
            img.set('src', app.icon);
            var bbox = img.getBoundingBox();
            var imgW = bbox[2];
            img.setTranslation((64 - imgW) / 2, 0);

            app.shellIcon.createChild('text')
                .setText(app.label)
                .setColor(0, 0, 0)
                .setAlignment('center-top')
                .setTranslation(64, 70)
                .setFont("LiberationFonts/LiberationSans-Regular.ttf")
                .setFontSize(20);
        }
        var self = me;
        setlistener('/instrumentation/clock/local-short-string', func(node) {
            self.clockElem.setText(node.getValue());
        }, 1, 1);
        setlistener('/instrumentation/efb/orientation-norm', func (node) {
            me.deviceRotation = node.getValue();
            me.rotate(me.deviceRotation);
        }, 0, 1);
        me.deviceRotation = getprop('/instrumentation/efb/orientation-norm') or 0;
        me.rotate(me.deviceRotation, 1);
    },

    rotate: func (rotationNorm, hard=0) {
        var prevRotation = me.reportedRotation;

        if (rotationNorm > 0.75) {
            me.reportedRotation = 1;
        }
        elsif (rotationNorm < 0.25) {
            me.reportedRotation = 0;
        }
        if (prevRotation != me.reportedRotation) {
            if (me.currentApp == nil) {
                # TODO: implement rotation for the shell
            }
            else {
                me.currentApp.rotate(me.reportedRotation, hard);
            }
        }
    },

    touch: func (args) {
        var x = math.floor(args.x * 512);
        var y = math.floor(768 - args.y * 768);
        if (y >= 736) {
            if (x < 171) {
                me.handleBack();
            }
            else if (x < 342) {
                me.handleHome();
            }
            else {
                me.handleMenu();
            }
        }
        else {
            # Shell: find icon
            if (me.currentApp == nil) {
                foreach (var appInfo; me.apps) {
                    if ((appInfo.page == me.shellPage) and
                        (x >= appInfo.box[0]) and
                        (y >= appInfo.box[1]) and
                        (x < appInfo.box[2]) and
                        (y < appInfo.box[3])) {
                        me.openApp(appInfo);
                        break;
                    }
                }
            }
            else {
                me.currentApp.touch(x, y);
            }
        }
    },

    wheel: func (axis, amount) {
        if (me.currentApp == nil) {
            # Once we get multiple screens, we might handle the event here.
        }
        else {
            me.currentApp.wheel(axis, amount);
        }
    },

    hideCurrentApp: func () {
        if (me.currentApp != nil) {
            me.currentApp.background();
            me.currentApp.masterGroup.hide();
            me.currentApp = nil;
        }
    },

    openShell: func () {
        me.hideCurrentApp();
        me.shellGroup.show();
    },

    openApp: func (appInfo) {
        me.hideCurrentApp();
        me.shellGroup.hide();
        if (appInfo.app == nil) {
            var masterGroup = me.clientGroup.createChild('group');
            appInfo.app = appInfo.loader(masterGroup);
            appInfo.app.setAssetDir(appInfo.basedir ~ '/');
            appInfo.app.initialize();
        }
        me.currentApp = appInfo.app;
        # Set current rotation, because the app may not have caught it yet
        me.currentApp.rotate(me.reportedRotation, 1);
        me.currentApp.masterGroup.show();
        me.currentApp.foreground();
    },

    handleMenu: func () {
        if (me.currentApp != nil) {
            me.currentApp.handleMenu();
        }
        else {
            # next shell page
        }
    },

    handleBack: func () {
        if (me.currentApp != nil) {
            me.currentApp.handleBack();
        }
        else {
            # previous shell page
        }
    },

    handleHome: func () {
        if (me.currentApp != nil) {
            me.openShell();
        }
    },
};

var initMaster = func {
    if (!contains(globals.efb, 'efbDisplay') or globals.efb.efbDisplay == nil) {
        globals.efb.efbDisplay = canvas.new({
            "name": "EFB",
            "size": [1024, 1536],
            "view": [512, 768],
            "mipmapping": 1
        });
        globals.efb.efbDisplay.addPlacement({"node": "EFBScreen"});
    }
    if (!contains(globals.efb, 'efbMaster') or globals.efb.efbMaster == nil) {
        globals.efb.efbMaster = globals.efb.efbDisplay.createGroup();
    }
    efbMaster = globals.efb.efbMaster;
    efbMaster.removeAllChildren();
    efb = EFB.new(efbMaster);
};

