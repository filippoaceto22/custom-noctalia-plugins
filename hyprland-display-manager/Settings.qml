import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

ColumnLayout {
    id: root

    // Plugin API (injected by the settings dialog system)
    property var pluginApi: null


    property string scriptPath: pluginApi?.pluginSettings?.scriptPath
                              ?? pluginApi?.manifest?.metadata?.defaultSettings?.scriptPath
                              ?? (Quickshell.env("HOME"))

   
    spacing: Style.marginM

    // Your settings controls here


     NTextInputButton {
        Layout.fillWidth: true
        label: pluginApi?.tr("settings.scriptPath.label")
        description: pluginApi?.tr("settings.scriptPath.description")
        placeholderText: Quickshell.env("HOME")
        text: root.scriptPath
        buttonIcon: "folder-open"
        buttonTooltip: pluginApi?.tr("settings.scriptPath.label")
        onInputEditingFinished: root.scriptPath = text
        onButtonClicked: scriptFolderPicker.openFilePicker()
    }


    



     NFilePicker {
        id: scriptFolderPicker
        selectionMode: "folders"
        title: pluginApi?.tr("settings.scriptPath.label")
        initialPath: root.scriptPath || Quickshell.env("HOME")
        onAccepted: paths => {
            if (paths.length > 0) {
                root.scriptPath = paths[0]
            }
        }
    }


   
    // Required: Save function called by the dialog
    function saveSettings() {
        pluginApi.pluginSettings.scriptPath = root.scriptPath
        pluginApi.saveSettings()
    }
}

