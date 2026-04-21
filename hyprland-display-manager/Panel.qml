import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import qs.Commons
import qs.Widgets
import qs.Services.UI

Item {
    id: root

    property var pluginApi: null
    property var main: pluginApi?.mainInstance

    // ✅ SOLO QUI
    readonly property var geometryPlaceholder: panelContainer
    readonly property bool allowAttach: true

    property real contentPreferredWidth: panelContainer.implicitWidth
    property real contentPreferredHeight: panelContainer.implicitHeight

    // 🔴 QUESTO È IL FIX CHIAVE
    implicitWidth: contentPreferredWidth
    implicitHeight: contentPreferredHeight

    // =========================
    NBox {
        id: panelContainer

        implicitWidth: 360
        implicitHeight: content.implicitHeight + Style.marginM * 2

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: Style.marginM
            spacing: Style.marginM

            // ================= HEADER
            // ColumnLayout {
            //     Layout.fillWidth: true

            //     Label {
            //         text: "Primary: " + (main?.stateData?.primary?.currentName || "-")
            //         color: Color.mOnSurface
            //     }

            //     Label {
            //         text: "Layout: " + main?.stateData?.layout?.value
            //         color: Color.mOnSurfaceVariant
            //     }

            //     Label {
            //         text: "Workspaces: " + main?.stateData?.workspaces?.value
            //         color: Color.mOnSurfaceVariant
            //     }
            // }

            // ================= LAYOUT
            RowLayout {
                Layout.fillWidth: true

                Label {
                    text:  pluginApi?.tr("panel.dispositions")
                    color: Color.mOnSurface
                }

                ComboBox {
                    Layout.fillWidth: true
                    model: main?.stateData?.layouts || []

                    onActivated: (i)=> {
                        main.pendingLayout = model[i]
                    }
                }

                NButton {
                    text: "Apply"
                    onClicked: main.run(`${main.monitorScript} apply ${main.pendingLayout}`)
                }
            }

            // ================= WORKSPACES
            RowLayout {
                Layout.fillWidth: true

                Label {
                    text:  pluginApi?.tr("panel.workspaces")
                    color: Color.mOnSurface
                }

                NButton {
                    text: "-"
                    onClicked: {
                        main.pendingWs--
                        main.run(`${main.monitorScript} set-ws-per-monitor ${main.pendingWs}`)
                    }
                }

                Label {
                    text: main.pendingWs
                    color: Color.mOnSurface
                }

                NButton {
                    text: "+"
                    onClicked: {
                        main.pendingWs++
                        main.run(`${main.monitorScript} set-ws-per-monitor ${main.pendingWs}`)
                    }
                }
            }

            // ================= PRIMARY
            RowLayout {
                Layout.fillWidth: true

                Label {
                    text:  pluginApi?.tr("panel.set-primary")
                    color: Color.mOnSurface
                }


            }
            ColumnLayout {
                Layout.fillWidth: true

                Repeater {
                    model: main?.stateData?.monitors || []

                    delegate: RowLayout {
                        Layout.fillWidth: true

                        RadioButton {
                            checked: main.selectedPrimary === main.monitorKey(modelData)
                        }

                        Label {
                            Layout.fillWidth: true
                            text: modelData.name
                            color: Color.mOnSurface
                        }

                        NButton {
                            text: "Set"
                            onClicked: main.setPrimary(modelData)
                        }
                    }
                }
            }

            // ================= FOOTER
            RowLayout {
                Layout.fillWidth: true

                NButton {
                    text: "Refresh"
                    onClicked: main.refresh()
                }

                Item { Layout.fillWidth: true }

                NButton {
                    text: "Close"
                    onClicked: pluginApi.closePanel(pluginApi.panelOpenScreen)
                }
            }
        }
    }
}