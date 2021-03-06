#!/bin/bash
#
# Initial data for Keystone using python-keystoneclient
#
# Tenant               User      Roles
# ------------------------------------------------------------------
# admin                admin     admin
# service              glance    admin
# service              nova      admin, [ResellerAdmin (swift only)]
# service              neutron   admin        # if enabled
# service              swift     admin        # if enabled
# service              cinder    admin        # if enabled
# service              heat      admin        # if enabled
# demo                 admin     admin
# demo                 demo      Member, anotherrole
# invisible_to_admin   demo      Member
# Tempest Only:
# alt_demo             alt_demo  Member
#
# Variables set before calling this script:
# SERVICE_TOKEN - aka admin_token in keystone.conf
# SERVICE_ENDPOINT - local Keystone admin endpoint
# SERVICE_TENANT_NAME - name of tenant containing service accounts
# SERVICE_HOST - host used for endpoint creation
# ENABLED_SERVICES - stack.sh's list of services to start
# DEVSTACK_DIR - Top-level DevStack directory
# KEYSTONE_CATALOG_BACKEND - used to determine service catalog creation

# Defaults
# --------

ADMIN_PASSWORD=${ADMIN_PASSWORD:-secrete}
SERVICE_PASSWORD=${SERVICE_PASSWORD:-$ADMIN_PASSWORD}
export SERVICE_TOKEN=$SERVICE_TOKEN
export SERVICE_ENDPOINT=$SERVICE_ENDPOINT
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}

function get_id () {
    echo `"$@" | awk '/ id / { print $4 }'`
}


# Tenants
# -------

ADMIN_TENANT=$(get_id keystone tenant-create --name=admin)
SERVICE_TENANT=$(get_id keystone tenant-create --name=$SERVICE_TENANT_NAME)
DEMO_TENANT=$(get_id keystone tenant-create --name=demo)
INVIS_TENANT=$(get_id keystone tenant-create --name=invisible_to_admin)


# Users
# -----

ADMIN_USER=$(get_id keystone user-create --name=admin \
                                         --pass="$ADMIN_PASSWORD" \
                                         --email=admin@example.com)
DEMO_USER=$(get_id keystone user-create --name=demo \
                                        --pass="$ADMIN_PASSWORD" \
                                        --email=demo@example.com)


# Roles
# -----

ADMIN_ROLE=$(get_id keystone role-create --name=admin)
# ANOTHER_ROLE demonstrates that an arbitrary role may be created and used
# TODO(sleepsonthefloor): show how this can be used for rbac in the future!
ANOTHER_ROLE=$(get_id keystone role-create --name=anotherrole)


# Add Roles to Users in Tenants
keystone user-role-add --user-id $ADMIN_USER --role-id $ADMIN_ROLE --tenant-id $ADMIN_TENANT
keystone user-role-add --user-id $ADMIN_USER --role-id $ADMIN_ROLE --tenant-id $DEMO_TENANT
keystone user-role-add --user-id $DEMO_USER --role-id $ANOTHER_ROLE --tenant-id $DEMO_TENANT

# The Member role is used by Horizon and Swift so we need to keep it:
MEMBER_ROLE=$(get_id keystone role-create --name=Member)
keystone user-role-add --user-id $DEMO_USER --role-id $MEMBER_ROLE --tenant-id $DEMO_TENANT
keystone user-role-add --user-id $DEMO_USER --role-id $MEMBER_ROLE --tenant-id $INVIS_TENANT


# Services
# --------

# Keystone
if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
	KEYSTONE_SERVICE=$(get_id keystone service-create \
		--name=keystone \
		--type=identity \
		--description="Keystone Identity Service")
	keystone endpoint-create \
	    --region RegionOne \
		--service_id $KEYSTONE_SERVICE \
		--publicurl "http://$SERVICE_HOST:\$(public_port)s/v2.0" \
		--adminurl "http://$SERVICE_HOST:\$(admin_port)s/v2.0" \
		--internalurl "http://$SERVICE_HOST:\$(public_port)s/v2.0"
fi

# Nova
if [[ "$ENABLED_SERVICES" =~ "n-cpu" ]]; then
    NOVA_USER=$(get_id keystone user-create \
        --name=nova \
        --pass="$SERVICE_PASSWORD" \
        --tenant-id $SERVICE_TENANT \
        --email=nova@example.com)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $NOVA_USER \
        --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        NOVA_SERVICE=$(get_id keystone service-create \
            --name=nova \
            --type=compute \
            --description="Nova Compute Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $NOVA_SERVICE \
            --publicurl "http://$SERVICE_HOST:\$(compute_port)s/v2/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:\$(compute_port)s/v2/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:\$(compute_port)s/v2/\$(tenant_id)s"

        # Create Nova V2.1 Services
        NOVA_V21_SERVICE=$(get_id keystone service-create \
            --name=novav21 \
            --type=computev21 \
            --description="Nova Compute Service V2.1")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $NOVA_V21_SERVICE \
            --publicurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s"
    fi

    # Nova needs ResellerAdmin role to download images when accessing
    # swift through the s3 api. The admin role in swift allows a user
    # to act as an admin for their tenant, but ResellerAdmin is needed
    # for a user to act as any tenant. The name of this role is also
    # configurable in swift-proxy.conf
    RESELLER_ROLE=$(get_id keystone role-create --name=ResellerAdmin)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $NOVA_USER \
        --role-id $RESELLER_ROLE
fi

# Heat
if [[ "$ENABLED_SERVICES" =~ "heat" ]]; then
    HEAT_API_CFN_PORT=${HEAT_API_CFN_PORT:-8000}
    HEAT_API_PORT=${HEAT_API_PORT:-8004}

    HEAT_USER=$(get_id keystone user-create --name=heat \
                                              --pass="$SERVICE_PASSWORD" \
                                              --tenant-id $SERVICE_TENANT \
                                              --email=heat@example.com)
    keystone user-role-add --tenant-id $SERVICE_TENANT \
                           --user-id $HEAT_USER \
                           --role-id $ADMIN_ROLE

    # heat_stack_user role is for users created by Heat
    STACK_USER_ROLE=$(get_id keystone role-create --name=heat_stack_user)

    # heat_stack_owner role is given to users who create Heat Stacks
    STACK_OWNER_ROLE=$(get_id keystone role-create --name=heat_stack_owner)

    # Give the role to the demo and admin users so they can create stacks
    # in either of the projects created by devstack
    keystone user-role-add \
        --tenant-id $DEMO_TENANT --user-id $DEMO_USER --role-id $STACK_OWNER_ROLE

    keystone user-role-add \
        --tenant-id $DEMO_TENANT --user-id $ADMIN_USER --role-id $STACK_OWNER_ROLE

    keystone user-role-add \
        --tenant-id $ADMIN_TENANT --user-id $ADMIN_USER --role-id $STACK_OWNER_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        HEAT_CFN_SERVICE=$(get_id keystone service-create \
            --name=heat-cfn \
            --type=cloudformation \
            --description="Heat CloudFormation Service")

        keystone endpoint-create \
            --region RegionOne \
            --service_id $HEAT_CFN_SERVICE \
            --publicurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
            --adminurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
            --internalurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1"

        HEAT_SERVICE=$(get_id keystone service-create \
            --name=heat \
            --type=orchestration \
            --description="Heat Service")

        keystone endpoint-create \
            --region RegionOne \
            --service_id $HEAT_SERVICE \
            --publicurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s"
    fi
fi

# Glance
if [[ "$ENABLED_SERVICES" =~ "g-api" ]]; then
    GLANCE_USER=$(get_id keystone user-create \
        --name=glance \
        --pass="$SERVICE_PASSWORD" \
        --tenant-id $SERVICE_TENANT \
        --email=glance@example.com)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $GLANCE_USER \
        --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        GLANCE_SERVICE=$(get_id keystone service-create \
            --name=glance \
            --type=image \
            --description="Glance Image Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $GLANCE_SERVICE \
            --publicurl "http://$SERVICE_HOST:9292" \
            --adminurl "http://$SERVICE_HOST:9292" \
            --internalurl "http://$SERVICE_HOST:9292"
    fi
fi

# Swift
if [[ "$ENABLED_SERVICES" =~ "swift" ]]; then
    SWIFT_USER=$(get_id keystone user-create \
        --name=swift \
        --pass="$SERVICE_PASSWORD" \
        --tenant-id $SERVICE_TENANT \
        --email=swift@example.com)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $SWIFT_USER \
        --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        SWIFT_SERVICE=$(get_id keystone service-create \
            --name=swift \
            --type="object-store" \
            --description="Swift Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $SWIFT_SERVICE \
            --publicurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8080" \
            --internalurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s"
    fi
fi

if [[ "$ENABLED_SERVICES" =~ "q-svc" ]]; then
    NEUTRON_USER=$(get_id keystone user-create \
        --name=neutron \
        --pass="$SERVICE_PASSWORD" \
        --tenant-id $SERVICE_TENANT \
        --email=neutron@example.com)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $NEUTRON_USER \
        --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        NEUTRON_SERVICE=$(get_id keystone service-create \
            --name=neutron \
            --type=network \
            --description="Quantum Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $NEUTRON_SERVICE \
            --publicurl "http://$SERVICE_HOST:9696/" \
            --adminurl "http://$SERVICE_HOST:9696/" \
            --internalurl "http://$SERVICE_HOST:9696/"
    fi
fi

# EC2
if [[ "$ENABLED_SERVICES" =~ "n-api" ]]; then
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        EC2_SERVICE=$(get_id keystone service-create \
            --name=ec2 \
            --type=ec2 \
            --description="EC2 Compatibility Layer")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $EC2_SERVICE \
            --publicurl "http://$SERVICE_HOST:8773/services/Cloud" \
            --adminurl "http://$SERVICE_HOST:8773/services/Admin" \
            --internalurl "http://$SERVICE_HOST:8773/services/Cloud"
    fi
fi

# S3
if [[ "$ENABLED_SERVICES" =~ "n-obj" || "$ENABLED_SERVICES" =~ "swift" ]]; then
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        S3_SERVICE=$(get_id keystone service-create \
            --name=s3 \
            --type=s3 \
            --description="S3")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $S3_SERVICE \
            --publicurl "http://$SERVICE_HOST:$S3_SERVICE_PORT" \
            --adminurl "http://$SERVICE_HOST:$S3_SERVICE_PORT" \
            --internalurl "http://$SERVICE_HOST:$S3_SERVICE_PORT"
    fi
fi

if [[ "$ENABLED_SERVICES" =~ "tempest" ]]; then
    # Tempest has some tests that validate various authorization checks
    # between two regular users in separate tenants
    ALT_DEMO_TENANT=$(get_id keystone tenant-create \
        --name=alt_demo)
    ALT_DEMO_USER=$(get_id keystone user-create \
        --name=alt_demo \
        --pass="$ADMIN_PASSWORD" \
        --email=alt_demo@example.com)
    keystone user-role-add \
        --tenant-id $ALT_DEMO_TENANT \
        --user-id $ALT_DEMO_USER \
        --role-id $MEMBER_ROLE
fi

if [[ "$ENABLED_SERVICES" =~ "c-api" ]]; then
    CINDER_USER=$(get_id keystone user-create --name=cinder \
                                              --pass="$SERVICE_PASSWORD" \
                                              --tenant-id $SERVICE_TENANT \
                                              --email=cinder@example.com)
    keystone user-role-add --tenant-id $SERVICE_TENANT \
                           --user-id $CINDER_USER \
                           --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        CINDER_SERVICE=$(get_id keystone service-create \
            --name=cinder \
            --type=volume \
            --description="Cinder Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $CINDER_SERVICE \
            --publicurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s"


        # Create Cinder V2 API
        CINDER_V2_SERVICE=$(get_id keystone service-create \
                        --name=cinderv2 \
                        --type=volumev2 \
                        --description="Cinder Volume Service V2")
        keystone endpoint-create \
                        --region RegionOne \
                        --service_id $CINDER_V2_SERVICE \
                        --publicurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
                        --adminurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
                        --internalurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s"
    fi
fi

# Ceilometer
if [[ "$ENABLED_SERVICES" =~ "ceilometer-api" ]]; then
    CEILOMETER_SERVICE_PROTOCOL=http
    CEILOMETER_SERVICE_HOST=$SERVICE_HOST
    CEILOMETER_SERVICE_PORT=${CEILOMETER_SERVICE_PORT:-8777}

    CEILOMETER_USER=$(get_id keystone user-create \
        --name=ceilometer \
        --pass="$SERVICE_PASSWORD" \
        --tenant-id $SERVICE_TENANT \
        --email=ceilometer@example.com)
    keystone user-role-add \
        --tenant-id $SERVICE_TENANT \
        --user-id $CEILOMETER_USER \
        --role-id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        CEILOMETER_SERVICE=$(get_id keystone service-create \
            --name=ceilometer \
            --type=metering \
            --description="OpenStack Telemetry Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $CEILOMETER_SERVICE \
            --publicurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
            --adminurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
            --internalurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/"
    fi
fi
