/* FROST Shell extension — targets GNOME Shell 45+ (ES module extensions).
 *
 * UNVERIFIED: written against the documented GNOME 45+ extension API
 * from spec/reference, but never run against a real gnome-shell process
 * (no Wayland/GNOME runtime available in the environment this was
 * written in). Treat as a solid starting point to test and fix on real
 * hardware/VM, not as confirmed-working code — see DESKTOP.README.md.
 *
 * Scope, deliberately: this does NOT reimplement a dock, quick-settings
 * panel, or notification system — GNOME Shell already has all three
 * (Quick Settings native since GNOME 43; the dock comes from the
 * separate, well-established "Dash to Dock" extension, configured by
 * frost-desktop.sh, not rewritten here). This extension only adds the
 * things that are genuinely FROST-specific: a Steam Mode quick toggle,
 * a small panel indicator, and the hidden easter egg keybinding.
 */

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const EASTER_EGG_LINES = [
    'Minimalist means every element earns its place.',
    'Frozen point: 0°C, 32°F, and exactly one distro.',
    'You found it. Most people never right-click the snowflake.',
];

function runDetached(argv) {
    try {
        const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        proc.wait_async(null, () => {});
    } catch (e) {
        logError(e, `frost-shell: failed to launch ${argv.join(' ')}`);
    }
}

const SteamModeToggle = GObject.registerClass(
class SteamModeToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({
            title: 'Steam Mode',
            iconName: 'applications-games-symbolic',
            toggleMode: true,
        });
        this.connect('clicked', () => this._onToggled());
    }

    _onToggled() {
        if (this.checked)
            runDetached(['steam', '-bigpicture']);
        else
            runDetached(['steam', '-shutdown']);
    }
});

// GNOME 45+'s real contract for `quickSettings.addExternalIndicator()` is
// a QuickSettings.SystemIndicator wrapper (it reads `quickSettingsItems`
// off the object passed in), NOT a bare QuickToggle — passing the toggle
// itself throws "can't access property 'forEach', items is undefined"
// deep in panel.js, since there's no `quickSettingsItems` array on it.
// VM-CONFIRMED (2026-08): this was a real bug here — see ARCHITECTURE.md.
const SteamModeIndicator = GObject.registerClass(
class SteamModeIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        const toggle = new SteamModeToggle();
        this.quickSettingsItems.push(toggle);
    }
});

const FrostIndicator = GObject.registerClass(
class FrostIndicator extends PanelMenu.Button {
    _init(extensionPath) {
        super._init(0.0, 'FROST', false);

        // The hexagon-in-crystal glyph is FROST's own signature mark —
        // deliberately not a generic weather/snow system icon — bundled
        // as a file next to the extension and loaded directly (see the
        // SVG's own header comment for why that's simpler than fighting
        // GNOME's symbolic-icon recolor pipeline for an unbundled icon).
        const iconFile = Gio.File.new_for_path(`${extensionPath}/icons/frost-hex.svg`);
        const icon = new St.Icon({
            gicon: new Gio.FileIcon({file: iconFile}),
            style_class: 'system-status-icon frost-panel-icon',
            icon_size: 16,
        });
        this.add_child(icon);

        const versionItem = new PopupMenu.PopupMenuItem('FROST OS', {reactive: false});
        this.menu.addMenuItem(versionItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const settingsItem = new PopupMenu.PopupMenuItem('Settings');
        settingsItem.connect('activate', () => runDetached(['gnome-control-center']));
        this.menu.addMenuItem(settingsItem);
    }
});

export default class FrostShellExtension extends Extension {
    enable() {
        this._settings = this.getSettings();

        this._indicator = new FrostIndicator(this.path);
        Main.panel.addToStatusArea(`${this.uuid}-indicator`, this._indicator, 1, 'right');

        // Quick Settings API (GNOME 43+): register an external indicator
        // rather than rebuilding the panel — this is the supported
        // extension point, not a private/internal hack.
        this._steamToggle = new SteamModeIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._steamToggle);

        Main.wm.addKeybinding(
            'easter-egg-keybinding',
            this._settings,
            Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL,
            () => this._revealEasterEgg()
        );
    }

    disable() {
        Main.wm.removeKeybinding('easter-egg-keybinding');

        this._steamToggle?.destroy();
        this._steamToggle = null;

        this._indicator?.destroy();
        this._indicator = null;

        this._settings = null;
    }

    _revealEasterEgg() {
        const line = EASTER_EGG_LINES[Math.floor(Math.random() * EASTER_EGG_LINES.length)];
        Main.notify('❄ FROST', line);
    }
}
