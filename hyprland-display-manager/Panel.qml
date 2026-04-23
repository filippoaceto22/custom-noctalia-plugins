import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets

// Panel Component
Item {
    id: root

    // Plugin API (injected by PluginPanelSlot)
    property var pluginApi: null



    property real contentPreferredWidth: 400 + Style.marginM + 2
    property real contentPreferredHeight: 350 + Style.marginM + 2

    property var main: pluginApi?.mainInstance


    readonly property var geometryPlaceholder: panelContainer
    readonly property bool allowAttach: true


    implicitWidth: contentPreferredWidth
    implicitHeight: contentPreferredHeight

    //anchors.fill: parent


    property int localWs: main.pendingWs
    property string selectedLayout: main?.pendingLayout ?? "line-left"

    readonly property var layouts: [{
        key: "line-left",
        name: "line-left"
    },
        {
            key: "line-right",
            name: "line-right"
        },
        {
            key: "line-top",
            name: "line-top"
        },
        {
            key: "line-bottom",
            name: "line-bottom"
        },
        {
            key: "split-lr",
            name: "split-lr"
        },
        {
            key: "split-tb",
            name: "split-tb"
        }]




NBox {
   id: panelContainer
    anchors.fill: parent
    color: "transparent"



        ColumnLayout {
                id: mainColumn
            anchors {
                fill: parent
                margins: Style.marginL
            }

            RowLayout {
                id: titleRow
                Layout.fillWidth: true
                spacing: Style.marginS

                NIcon {
                    icon: "devices"
                    pointSize: Style.fontSizeL
                    color: Color.mPrimary
                }

                NText {
                    text: pluginApi?.tr("panel.title")
                    pointSize: Style.fontSizeL
                    font.weight: Style.fontWeightBold
                    color: Color.mOnSurface
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: disposition.implicitHeight + Style.marginM * 2
                color: Color.mSurfaceVariant
                radius: Style.radiusM

                ColumnLayout {
                    id: disposition
                    anchors {
                        fill: parent
                        margins: Style.marginM
                    }
                    spacing: Style.marginS

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.marginS



                        NComboBox {
                            Layout.fillWidth: true
                            label: pluginApi?.tr("panel.dispositions")
                            description: pluginApi?.tr("panel.dispositionsDesc")
                            model: root.layouts
                            currentKey: root.selectedLayout
                            onSelected: key => {
                                root.selectedLayout = key
                                main.pendingLayout = key
                            }
                        }

                        NButton {
                            text: "Apply"
                            onClicked: main.run(`${main.monitorScript} apply $ {root.selectedLayout}`)
                        }
                    }
                }
            }


            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: wsColumn.implicitHeight + Style.marginM * 2
                color: Color.mSurfaceVariant
                radius: Style.radiusM

                ColumnLayout {
                    id: wsColumn
                    anchors {
                        fill: parent
                        margins: Style.marginM
                    }
                    spacing: Style.marginS

                    RowLayout {
                        NSpinBox {
                            Layout.fillWidth: true
                            visible: true
                            label: pluginApi?.tr("panel.workspaces")
                            description: pluginApi?.tr("panel.workspacesDesc")
                            from: 1
                            to: 20
                            stepSize: 1
                            value:main.pendingWs
                            onValueChanged: {
                                localWs = value
                            }
                        }

                        NButton {
                            text: "Apply"
                            onClicked: {
                                main.pendingWs = localWs
                                main.run(`${main.monitorScript} set-ws-per-monitor ${localWs}`)
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: primary.implicitHeight + Style.marginM * 2
                color: Color.mSurfaceVariant
                radius: Style.radiusM

                ColumnLayout {
                    id: primary
                    anchors {
                        fill: parent
                        margins: Style.marginM
                    }
                    spacing: Style.marginS
                    NText {
                        text: pluginApi?.tr("panel.set-primary")
                        font.pointSize: Style.fontSizeM * Style.uiScaleRatio
                        font.weight: Font.Medium
                        color: Color.mOnSurface
                    }
                    Repeater {
                        model: main?.stateData?.monitors || []

                        delegate:
                        RowLayout {
                            Layout.fillWidth: true

                            NRadioButton {
                                Layout.alignment: Qt.AlignLeft
                                enabled:false
                                checked: main.selectedPrimary === main.monitorKey(modelData)
                            }

                            NLabel {
                                Layout.fillWidth: true
                                label: modelData.name
                            }

                            NButton {
                                text: "Set"
                                onClicked: main.setPrimary(modelData)
                            }
                        }
                    }
                }
            }

        }
    }
}