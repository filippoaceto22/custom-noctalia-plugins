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

   
    readonly property var geometryPlaceholder: panelContainer
    readonly property bool allowAttach: true

    property real contentPreferredWidth: panelContainer.implicitWidth
    property real contentPreferredHeight: panelContainer.implicitHeight

    implicitWidth: contentPreferredWidth
    implicitHeight: contentPreferredHeight

    property int localWs: main.pendingWs
    property string selectedLayout: main?.pendingLayout ?? "line-left"

    readonly property var layouts: [
    {
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
    }
  ]


    // =========================
    NBox {
        id: panelContainer

        implicitWidth: 450
        implicitHeight: content.implicitHeight + Style.marginM * 2

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: Style.marginM
            spacing: Style.marginM


            // ================= LAYOUT
            RowLayout {
                Layout.fillWidth: true



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
                

                // ComboBox {
                //     Layout.fillWidth: true
                //     model: main?.stateData?.layouts || []

                //     onActivated: (i)=> {
                //         main.pendingLayout = model[i]
                //     }
                // }

                NButton {
                    text: "Apply"
                    onClicked: main.run(`${main.monitorScript} apply ${root.selectedLayout}`)
                }
            }

        NDivider {
          Layout.fillWidth: true
        }

               ColumnLayout {   // Panel Height (hidden when fullscreen)
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


          
      NDivider {
          Layout.fillWidth: true
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
                width: parent.width

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

    NDivider {
          Layout.fillWidth: true
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