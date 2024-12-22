# Add Replica

- [Add Replica](#Add-replica)
  - [Introduction](#Introduction)
  - [Adding a replica to standard and large infrastructures](#Adding-a-replica-to-standard-and-large-infrastructures)
  - [Adding a Replica to extra large infrastructure](#Adding-a-Replica-to-extra-large-infrastructure)
  - [Running the `add_replica` plan](#running-the-add_replica-plan)
  - [Parameters](#parameters)

## Introduction

The `peadm::add_replica` plan is designed to setup disaster recovery (DR) of a Puppet Enterprise primary server. This is achieved by adding a primary replica to your system. Although this plan doesn't change your PE architecture, adding DR depends on the structure of your current architecture.

In the case of standard and large installations, DR can be achieved by simply utilising this plan and adding the primary replica. In the case of an extra large infrastructure which includes an external DB, a replica DB is also required. This can be done with the `peadm::add_database` plan. For more detail see [Adding External Databases with peadm::add_database](expanding.md#adding-external-databases-with-peadmadd_database).

Please note, to setup a replica you must have Code Manager configured. To learn more about code manager, please see [Puppet Docs](help.puppet.com).

...

## Adding a replica to standard and large infrastructures
Below is an example of the required parameters to add a primary replica. These parameters can be passed in-line or as a params file.

```json
{
  "primary_host":  "pe-core-0.lab1.puppet.vm",
  "replica_host": "pe-replica-0.lab1.puppet.vm"
}
```

## Adding a Replica to extra large infrastructure
In the below example, we already have an external DB and a replica of it. This means that we should pass in the additional parameter of the replica's hostname.

```json
{
  "primary_host":  "pe-xl-core-0.lab1.puppet.vm",
  "compiler_host": "pe-xl-replica-0.lab1.puppet.vm",
  "replica_postgresql_host": "pe-xl-postgresql-replica-0.lab1.puppet.vm"
}
```

## Running the `add_replica` plan

```
bolt plan run peadm::add_replica --params @params.json 
```

The plan performs the following steps:

1. Installs the Puppet agent on the new replica host.
2. Updates classifications with new replica configuration.
3. Provisions the infrastructure with PE.

## Parameters

### `primary_host`

- **Type:** `Peadm::SingleTargetSpec`
- **Description:**  
  The hostname and certname of the PE primary server.

### `replica_host`

- **Type:** `Peadm::SingleTargetSpec`
- **Description:**  
  The hostname and certname of the replica VM.

### `token_file`

- **Type:** `Optional[String]`
- **Description:**  
  The Path to token file, only required if located in a non-default location.



## Replica promotion and Replica replacement

Please see the notes on these scenarios in [automated Recovery](automated_recovery.md#recover-from-failed-primary-puppet-server)

## Known Issue on Puppet Enterprise Version 2021.x

When running the add_replica plan to replace an existing replica in your infrastructure, the old replica will not be removed as expected. Instead, both the old and new primary replicas will be present.

This is a known issue and will be fixed in a future release.