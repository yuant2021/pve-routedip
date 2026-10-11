/*
 * pve-routedip web UI
 *
 *  Datacenter -> Routed IP   cluster options and all routed NICs of the cluster
 *  VM -> Routed IP           routed IPs of the VM's NICs, with their live state
 *
 * Loaded after pvemanagerlib.js through a script tag pve-routedip adds to
 * /usr/share/pve-manager/index.html.tpl.
 */
Ext.ns('PVE.routedip');

PVE.routedip.Utils = {
    splitCidrs: function (value) {
        return (value || '').split(/[\s,;]+/).filter((v) => v !== '');
    },

    // any prefix length, a plain address is a host route
    isValidCidr: function (text) {
        let parts = text.split('/');
        if (parts.length > 2) {
            return false;
        }
        let [ip, len] = parts;
        if (len !== undefined && !/^\d{1,3}$/.test(len)) {
            return false;
        }
        let max;
        if (Proxmox.Utils.IP4_match.test(ip)) {
            max = 32;
        } else if (Proxmox.Utils.IP6_match.test(ip)) {
            max = 128;
        } else {
            return false;
        }
        return len === undefined || parseInt(len, 10) <= max;
    },

    validateCidrs: function (value) {
        let invalid = PVE.routedip.Utils.splitCidrs(value).filter(
            (cidr) => !PVE.routedip.Utils.isValidCidr(cidr),
        );
        if (invalid.length) {
            return gettext('Invalid IP address or network') + ': ' + Ext.htmlEncode(invalid[0]);
        }
        return true;
    },

    renderCidrs: function (value) {
        return PVE.routedip.Utils.splitCidrs(value).map(Ext.htmlEncode).join('<br>');
    },

    renderTapOnly: function (value, metaData, record) {
        if (record.data.routed === false) {
            return '';
        }
        return Proxmox.Utils.format_boolean(value);
    },

    // only applied to tap-only devices
    renderRpFilter: function (value, metaData, record) {
        if (record.data.routed === false) {
            return '';
        }
        if (!record.data['tap-only']) {
            return '-';
        }
        return Proxmox.Utils.format_boolean(value);
    },

    renderState: function (value, metaData, record) {
        if (!record.data.routed) {
            return '';
        }
        let icon, text;
        switch (value) {
            case 'active':
                icon = 'fa-check-circle good';
                text = gettext('Active');
                break;
            case 'stopped':
                icon = 'fa-stop-circle';
                text = gettext('Not running here');
                break;
            case 'migrating':
                icon = 'fa-refresh warning';
                text = gettext('Migrating');
                break;
            case 'error':
                icon = 'fa-times-circle critical';
                text = gettext('Error');
                break;
            default:
                return Ext.htmlEncode(value ?? '');
        }
        let res = `<i class="fa fa-fw ${icon}"></i> ${text}`;
        let tips = [];
        if (record.data.error) {
            let error = Ext.htmlEncode(record.data.error);
            tips.push(error);
            res += `: ${error}`;
        }
        if (record.data.warning) {
            let warning = Ext.htmlEncode(record.data.warning);
            tips.push(warning);
            res += `<br><i class="fa fa-fw fa-exclamation-triangle warning"></i> ${warning}`;
        }
        if (tips.length) {
            metaData.tdAttr = `data-qtip="${Ext.htmlEncode(tips.join('<br>'))}"`;
        }
        return res;
    },

    renderNic: function (value, metaData, record) {
        let res = Ext.htmlEncode(value);
        if (record.data.missing) {
            res += ` <i class="fa fa-exclamation-triangle warning" data-qtip="${gettext(
                'The VM has no such network device',
            )}"></i>`;
        }
        return res;
    },

    renderBridge: function (value, metaData, record) {
        if (!value) {
            return '';
        }
        let res = Ext.htmlEncode(value);
        if (record.data.tag) {
            res += ` (VLAN ${Ext.htmlEncode(record.data.tag)})`;
        }
        return res;
    },

    canEdit: function () {
        let caps = Ext.state.Manager.get('GuiCap');
        return !!caps.vms['VM.Config.Network'] && !!caps.dc['Sys.Modify'];
    },
};

Ext.define('pve-routedip-nic', {
    extend: 'Ext.data.Model',
    fields: [
        'net',
        'bridge',
        'tag',
        'macaddr',
        'cidr',
        'gateway4',
        'gateway6',
        'gateways',
        'state',
        'device',
        'error',
        'warning',
        'digest',
        { name: 'routed', type: 'boolean' },
        { name: 'missing', type: 'boolean' },
        { name: 'tap-only', type: 'boolean' },
        { name: 'rp-filter', type: 'boolean' },
    ],
    idProperty: 'net',
});

Ext.define('pve-routedip-cluster-nic', {
    extend: 'Ext.data.Model',
    fields: [
        { name: 'vmid', type: 'integer' },
        'net',
        'node',
        'cidr',
        'gateway4',
        'gateway6',
        { name: 'tap-only', type: 'boolean' },
        { name: 'rp-filter', type: 'boolean' },
        { name: 'orphan', type: 'boolean' },
        {
            name: 'id',
            calculate: (data) => `${data.vmid}/${data.net}`,
        },
    ],
    idProperty: 'id',
    proxy: {
        type: 'proxmox',
        url: '/api2/json/cluster/routedip/vms',
    },
});

Ext.define('PVE.routedip.NicInputPanel', {
    extend: 'Proxmox.panel.InputPanel',
    alias: 'widget.pveRoutedIPNicInputPanel',

    // false when creating: nothing to delete then
    isEdit: true,

    onGetValues: function (values) {
        let me = this;

        let addDelete = (key) => {
            if (values.delete === undefined) {
                values.delete = key;
            } else if (Ext.isArray(values.delete)) {
                values.delete.push(key);
            } else {
                values.delete = [values.delete, key];
            }
        };

        let cidrs = PVE.routedip.Utils.splitCidrs(values.cidr);
        if (cidrs.length) {
            values.cidr = cidrs.join(';');
        } else {
            delete values.cidr;
            if (me.isEdit) {
                addDelete('cidr');
            }
        }
        values['tap-only'] = values['tap-only'] ? 1 : 0;
        // not submitted while disabled (tap-only off), the stored value stays
        if (values['rp-filter'] !== undefined) {
            values['rp-filter'] = values['rp-filter'] ? 1 : 0;
        }

        return values;
    },

    onSetValues: function (values) {
        if (values.cidr !== undefined) {
            values.cidr = PVE.routedip.Utils.splitCidrs(values.cidr).join('\n');
        }
        return values;
    },

    initComponent: function () {
        let me = this;

        let items = me.items || [];
        items.push(
            {
                xtype: 'proxmoxcheckbox',
                name: 'tap-only',
                fieldLabel: gettext('Tap only'),
                boxLabel: gettext('Do not insert the tap device into the bridge'),
                uncheckedValue: 0,
                listeners: {
                    change: function (field, value) {
                        me.down('field[name=rp-filter]').setDisabled(!value);
                    },
                },
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'rp-filter',
                fieldLabel: 'rp_filter',
                boxLabel: gettext('Strict reverse path filter (IPv4), only routed source addresses'),
                uncheckedValue: 0,
                disabled: true,
            },
            {
                xtype: 'textareafield',
                name: 'cidr',
                fieldLabel: gettext('Routed IPs'),
                height: 130,
                emptyText: '203.0.113.10\n198.51.100.0/29\n2001:db8:10::/64',
                validator: PVE.routedip.Utils.validateCidrs,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'gateway4',
                fieldLabel: gettext('IPv4 Gateway'),
                emptyText: gettext('Cluster default'),
                vtype: 'IPAddress',
                deleteEmpty: me.isEdit,
            },
            {
                xtype: 'proxmoxtextfield',
                name: 'gateway6',
                fieldLabel: gettext('IPv6 Gateway'),
                emptyText: gettext('Cluster default'),
                vtype: 'IP6Address',
                deleteEmpty: me.isEdit,
            },
            {
                xtype: 'displayfield',
                userCls: 'pmx-hint',
                value: gettext(
                    'One address or network per line, any prefix length. Changes are applied to the running VM immediately.',
                ),
            },
        );
        me.items = items;

        me.callParent();
    },
});

// Edit the routed IPs of one NIC. With nodename/vmid/net given the NIC is fixed,
// without, VM and NIC are selected in the dialog.
Ext.define('PVE.routedip.NicEdit', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveRoutedIPNicEdit',

    width: 520,
    method: 'PUT',

    nodename: undefined,
    vmid: undefined,
    net: undefined,

    initComponent: function () {
        let me = this;

        let fixed = me.vmid !== undefined && me.net !== undefined;
        let items = [];

        if (fixed) {
            me.url = `/api2/extjs/nodes/${me.nodename}/qemu/${me.vmid}/routedip/${me.net}`;
            me.subject = `${gettext('Routed IP')}: VM ${me.vmid}, ${me.net}`;
            me.autoLoad = true;
        } else {
            me.isCreate = true;
            me.isAdd = true;
            me.subject = gettext('Routed IP');
            // not used for loading, the submit URL depends on the selected VM
            me.url = '/api2/extjs/cluster/routedip/vms';
            me.submitUrl = function () {
                let vmField = me.down('field[name=vmid]');
                let vm = vmField.getStore().findRecord('vmid', vmField.getValue(), 0, false, true, true);
                let net = me.down('field[name=net]').getValue();
                return `/api2/extjs/nodes/${vm.data.node}/qemu/${vm.data.vmid}/routedip/${net}`;
            };

            items.push(
                {
                    xtype: 'vmComboSelector',
                    name: 'vmid',
                    fieldLabel: gettext('VM'),
                    submitValue: false,
                    allowBlank: false,
                    store: {
                        model: 'PVEResources',
                        autoLoad: true,
                        sorters: 'vmid',
                        filters: [{ property: 'type', value: 'qemu' }],
                    },
                    listeners: {
                        change: function (field, vmid) {
                            me.loadNics(field, vmid);
                        },
                    },
                },
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'net',
                    fieldLabel: gettext('Network Device'),
                    submitValue: false,
                    allowBlank: false,
                    disabled: true,
                    comboItems: [],
                    listeners: {
                        change: function (field, net) {
                            me.loadNic(net);
                        },
                    },
                },
            );
        }

        me.inputPanel = Ext.create('PVE.routedip.NicInputPanel', {
            isEdit: fixed,
            items: items,
        });

        Ext.apply(me, { items: [me.inputPanel] });

        me.callParent();
    },

    // create mode: fill the NIC selector of the chosen VM
    loadNics: function (vmField, vmid) {
        let me = this;

        let netField = me.down('field[name=net]');
        netField.setComboItems([]);
        netField.setValue(null);
        netField.setDisabled(true);

        let vm = vmid ? vmField.getStore().findRecord('vmid', vmid, 0, false, true, true) : null;
        if (!vm) {
            return;
        }
        me.selectedNode = vm.data.node;

        Proxmox.Utils.API2Request({
            url: `/nodes/${vm.data.node}/qemu/${vmid}/routedip`,
            method: 'GET',
            waitMsgTarget: me,
            success: function (response) {
                let items = response.result.data
                    .filter((nic) => !nic.missing && nic.bridge)
                    .map((nic) => {
                        let text = `${nic.net} (${nic.bridge}, ${nic.macaddr || '-'})`;
                        if (nic.routed) {
                            text += ' - ' + gettext('routed');
                        }
                        return [nic.net, text];
                    });
                netField.setComboItems(items);
                netField.setDisabled(items.length === 0);
                if (items.length) {
                    netField.setValue(items[0][0]);
                }
            },
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
        });
    },

    // create mode: start from the current config of the chosen NIC
    loadNic: function (net) {
        let me = this;

        let vmid = me.down('field[name=vmid]').getValue();
        if (!net || !vmid || !me.selectedNode) {
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${me.selectedNode}/qemu/${vmid}/routedip/${net}`,
            method: 'GET',
            waitMsgTarget: me,
            success: function (response) {
                let data = response.result.data;
                me.digest = data.digest;
                me.inputPanel.setValues({
                    cidr: data.cidr ?? '',
                    'tap-only': data['tap-only'] ?? 0,
                    'rp-filter': data['rp-filter'] ?? 0,
                    gateway4: data.gateway4 ?? '',
                    gateway6: data.gateway6 ?? '',
                });
            },
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
        });
    },
});

// VM -> Routed IP
Ext.define('PVE.routedip.GuestPanel', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveRoutedIPGuestPanel',

    stateful: true,
    stateId: 'grid-routedip-guest',

    initComponent: function () {
        let me = this;

        let nodename = me.pveSelNode.data.node;
        let vmid = me.pveSelNode.data.vmid;
        let baseUrl = `/nodes/${nodename}/qemu/${vmid}/routedip`;
        let canEdit = PVE.routedip.Utils.canEdit();

        let store = Ext.create('Proxmox.data.UpdateStore', {
            storeid: `pve-routedip-guest-${vmid}`,
            interval: 3000,
            model: 'pve-routedip-nic',
            proxy: {
                type: 'proxmox',
                url: `/api2/json${baseUrl}`,
            },
        });

        let sm = Ext.create('Ext.selection.RowModel', {});

        let runEditor = function () {
            let rec = sm.getSelection()[0];
            if (!rec || rec.data.missing || !canEdit) {
                return;
            }
            Ext.create('PVE.routedip.NicEdit', {
                nodename: nodename,
                vmid: vmid,
                net: rec.data.net,
                autoShow: true,
                listeners: {
                    destroy: () => store.load(),
                },
            });
        };

        Ext.apply(me, {
            store: store,
            selModel: sm,
            tbar: [
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Edit'),
                    disabled: true,
                    selModel: sm,
                    enableFn: (rec) => canEdit && !rec.data.missing,
                    handler: runEditor,
                },
                {
                    xtype: 'proxmoxStdRemoveButton',
                    selModel: sm,
                    baseurl: baseUrl,
                    enableFn: (rec) => canEdit && rec.data.routed,
                    getUrl: (rec) => `${baseUrl}/${rec.data.net}`,
                    customConfirmationMessage: gettext(
                        'Are you sure you want to remove the routed IP configuration of {0}?',
                    ),
                    callback: () => store.load(),
                },
            ],
            viewConfig: {
                trackOver: false,
            },
            columns: [
                {
                    header: gettext('Device'),
                    dataIndex: 'net',
                    width: 90,
                    renderer: PVE.routedip.Utils.renderNic,
                },
                {
                    header: gettext('Bridge'),
                    dataIndex: 'bridge',
                    width: 130,
                    renderer: PVE.routedip.Utils.renderBridge,
                },
                {
                    header: gettext('Tap only'),
                    dataIndex: 'tap-only',
                    width: 80,
                    renderer: PVE.routedip.Utils.renderTapOnly,
                },
                {
                    header: 'rp_filter',
                    dataIndex: 'rp-filter',
                    width: 80,
                    renderer: PVE.routedip.Utils.renderRpFilter,
                },
                {
                    header: gettext('Routed IPs'),
                    dataIndex: 'cidr',
                    flex: 2,
                    minWidth: 160,
                    renderer: PVE.routedip.Utils.renderCidrs,
                },
                {
                    header: gettext('Gateway'),
                    dataIndex: 'gateways',
                    flex: 1,
                    minWidth: 150,
                    renderer: (v) => PVE.routedip.Utils.renderCidrs(v),
                },
                {
                    header: gettext('Route device'),
                    dataIndex: 'device',
                    width: 110,
                    renderer: Ext.htmlEncode,
                },
                {
                    header: gettext('State'),
                    dataIndex: 'state',
                    flex: 2,
                    minWidth: 150,
                    cellWrap: true,
                    renderer: PVE.routedip.Utils.renderState,
                },
            ],
            listeners: {
                itemdblclick: runEditor,
                destroy: () => store.stopUpdate(),
            },
        });

        me.callParent();

        Proxmox.Utils.monStoreErrors(me, store, true);
        store.startUpdate();
    },
});

// Datacenter -> Routed IP: options
Ext.define('PVE.routedip.OptionsGrid', {
    extend: 'Proxmox.grid.ObjectGrid',
    alias: 'widget.pveRoutedIPOptions',

    url: '/api2/json/cluster/routedip/options',
    editorConfig: {
        url: '/api2/extjs/cluster/routedip/options',
    },
    interval: 5000,
    cwidth1: 200,

    initComponent: function () {
        let me = this;

        let caps = Ext.state.Manager.get('GuiCap');
        let canEdit = !!caps.dc['Sys.Modify'];

        me.add_text_row('gateway4', gettext('IPv4 Gateway'), {
            defaultValue: '169.254.0.1',
            deleteEmpty: true,
            vtype: 'IPAddress',
        });
        me.add_text_row('gateway6', gettext('IPv6 Gateway'), {
            defaultValue: 'fe80::1',
            deleteEmpty: true,
            vtype: 'IP6Address',
        });
        me.add_text_row('gateway-mac', gettext('Tap MAC address'), {
            defaultValue: 'fe:ff:ff:ff:ff:ff',
            deleteEmpty: true,
            vtype: 'MacAddress',
        });

        if (!canEdit) {
            for (const row of Object.values(me.rows)) {
                delete row.editor;
            }
        }

        me.selModel = Ext.create('Ext.selection.RowModel', {});

        Ext.apply(me, {
            tbar: [
                {
                    text: gettext('Edit'),
                    xtype: 'proxmoxButton',
                    disabled: true,
                    hidden: !canEdit,
                    selModel: me.selModel,
                    handler: () => me.run_editor(),
                },
            ],
            listeners: {
                itemdblclick: me.run_editor,
            },
        });

        me.callParent();

        me.on('activate', me.rstore.startUpdate);
        me.on('destroy', me.rstore.stopUpdate);
        me.rstore.startUpdate();
    },
});

// Datacenter -> Routed IP: all routed NICs
Ext.define('PVE.routedip.ClusterNicGrid', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveRoutedIPClusterNics',

    stateful: true,
    stateId: 'grid-routedip-cluster',

    initComponent: function () {
        let me = this;

        let canEdit = PVE.routedip.Utils.canEdit();

        let store = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-routedip-cluster-nics',
            interval: 5000,
            model: 'pve-routedip-cluster-nic',
            sorters: [{ property: 'vmid' }, { property: 'net' }],
        });

        let resources = PVE.data.ResourceStore;
        let guestName = (vmid) => {
            let rec = resources.findRecord('vmid', vmid, 0, false, true, true);
            return rec ? rec.data.name : '';
        };

        let sm = Ext.create('Ext.selection.RowModel', {});

        let openEditor = function (config) {
            Ext.create('PVE.routedip.NicEdit', {
                autoShow: true,
                listeners: { destroy: () => store.load() },
                ...config,
            });
        };

        let runEditor = function () {
            let rec = sm.getSelection()[0];
            if (!rec || rec.data.orphan || !canEdit) {
                return;
            }
            openEditor({ nodename: rec.data.node, vmid: rec.data.vmid, net: rec.data.net });
        };

        Ext.apply(me, {
            store: store,
            selModel: sm,
            tbar: [
                {
                    text: gettext('Add'),
                    disabled: !canEdit,
                    handler: () => openEditor({}),
                },
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Edit'),
                    disabled: true,
                    selModel: sm,
                    enableFn: (rec) => canEdit && !rec.data.orphan,
                    handler: runEditor,
                },
                {
                    xtype: 'proxmoxStdRemoveButton',
                    selModel: sm,
                    enableFn: (rec) => canEdit && !rec.data.orphan,
                    getUrl: (rec) =>
                        `/nodes/${rec.data.node}/qemu/${rec.data.vmid}/routedip/${rec.data.net}`,
                    getRecordName: (rec) => `VM ${rec.data.vmid} ${rec.data.net}`,
                    callback: () => store.load(),
                },
            ],
            viewConfig: {
                trackOver: false,
            },
            columns: [
                {
                    header: 'VMID',
                    dataIndex: 'vmid',
                    width: 80,
                },
                {
                    header: gettext('Name'),
                    // not a model field: sorting by VMID must not mark this column
                    dataIndex: 'name',
                    flex: 1,
                    sortable: false,
                    renderer: (value, meta, rec) =>
                        rec.data.orphan
                            ? `<i>${gettext('deleted')}</i>`
                            : Ext.htmlEncode(guestName(rec.data.vmid)),
                },
                {
                    header: gettext('Node'),
                    dataIndex: 'node',
                    width: 100,
                    renderer: Ext.htmlEncode,
                },
                {
                    header: gettext('Device'),
                    dataIndex: 'net',
                    width: 80,
                },
                {
                    header: gettext('Tap only'),
                    dataIndex: 'tap-only',
                    width: 80,
                    renderer: Proxmox.Utils.format_boolean,
                },
                {
                    header: 'rp_filter',
                    dataIndex: 'rp-filter',
                    width: 80,
                    renderer: PVE.routedip.Utils.renderRpFilter,
                },
                {
                    header: gettext('Routed IPs'),
                    dataIndex: 'cidr',
                    flex: 2,
                    renderer: PVE.routedip.Utils.renderCidrs,
                },
                {
                    header: gettext('Gateway override'),
                    dataIndex: 'gateway4',
                    flex: 1,
                    sortable: false,
                    renderer: (v, meta, rec) =>
                        [rec.data.gateway4, rec.data.gateway6]
                            .filter((gw) => !!gw)
                            .map(Ext.htmlEncode)
                            .join('<br>'),
                },
            ],
            listeners: {
                itemdblclick: runEditor,
                destroy: () => store.stopUpdate(),
            },
        });

        me.callParent();

        Proxmox.Utils.monStoreErrors(me, store, true);
        store.startUpdate();
    },
});

Ext.define('PVE.routedip.ClusterPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveRoutedIPClusterPanel',

    layout: {
        type: 'vbox',
        align: 'stretch',
    },

    items: [
        {
            xtype: 'pveRoutedIPOptions',
            title: gettext('Options'),
            height: 160,
            border: false,
        },
        {
            xtype: 'pveRoutedIPClusterNics',
            title: gettext('Routed network devices'),
            flex: 1,
            border: false,
        },
    ],
});

// add the panels to the VM and datacenter config views
Ext.define('PVE.routedip.ConfigPanelOverride', {
    override: 'PVE.panel.Config',

    initComponent: function () {
        let me = this;

        let insertBefore = function (item, beforeId) {
            let items = me.items || [];
            let pos = items.findIndex((i) => i.itemId === beforeId);
            if (pos < 0) {
                items.push(item);
            } else {
                items.splice(pos, 0, item);
            }
            me.items = items;
        };

        try {
            let caps = Ext.state.Manager.get('GuiCap');
            if (me.$className === 'PVE.qemu.Config' && caps.vms['VM.Audit'] && !me.pveSelNode.data.template) {
                insertBefore(
                    {
                        xtype: 'pveRoutedIPGuestPanel',
                        title: gettext('Routed IP'),
                        iconCls: 'fa fa-road',
                        itemId: 'routedip',
                    },
                    'firewall',
                );
            } else if (me.$className === 'PVE.dc.Config' && caps.dc['Sys.Audit']) {
                insertBefore(
                    {
                        xtype: 'pveRoutedIPClusterPanel',
                        title: gettext('Routed IP'),
                        iconCls: 'fa fa-road',
                        itemId: 'routedip',
                    },
                    'firewall',
                );
            }
        } catch (err) {
            console.error('pve-routedip: unable to add panel', err);
        }

        me.callParent(arguments);
    },
});
