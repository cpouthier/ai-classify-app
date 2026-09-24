# Puls8 BC/DR demo, sample knowledge base entry

# Business Continuity vs Disaster Recovery

Business Continuity (BC) and Disaster Recovery (DR) are often used as synonyms, but they
answer two different questions. BC asks: "How do we keep the business running when
something fails?" DR asks: "How do we bring the business back after something major
has gone wrong?" A resilient Kubernetes platform needs both.

## Key definitions

- **RPO (Recovery Point Objective)**: the maximum amount of data the business accepts to
  lose, expressed as time. An RPO of 1 hour means losing up to 1 hour of data is acceptable.
- **RTO (Recovery Time Objective)**: the maximum time the business accepts for a service
  to be unavailable before it is restored.

## Business Continuity

Business Continuity is about **availability**. Its goal is to keep applications and data
accessible through a component failure, with no or minimal interruption for users.

- **Typical scope**: failure of a disk, a pod or a worker node inside a cluster.
- **Typical targets**: RPO = 0 (no data loss) and an RTO measured in seconds or minutes.
- **How it works**: redundancy and automatic failover. Data is replicated synchronously
  across nodes, so when one node fails, the application restarts elsewhere and keeps
  using a healthy copy of its data.
- **Business perspective**: users barely notice the incident. There is no ticket, no
  manual action and no data loss.

In this environment, Business Continuity is delivered by **DataCore Puls8**, which provides
replicated persistent volumes and automatic failover when a worker node is lost.

## Disaster Recovery

Disaster Recovery is about **recoverability**. Its goal is to restore applications and
data after a major incident that redundancy alone cannot absorb.

- **Typical scope**: loss of a whole cluster, a datacenter or a cloud region, ransomware,
  human error (a deleted namespace, a bad upgrade) or logical data corruption.
- **Typical targets**: RPO and RTO defined by business SLAs, for example an hourly backup
  (RPO = 1 hour) and a restore within 30 minutes (RTO = 30 minutes).
- **How it works**: independent, point-in-time copies of the application stored outside
  the cluster, ideally immutable, and a tested process to restore them on another cluster.
- **Business perspective**: the business accepts a short interruption and a bounded data
  loss, but is guaranteed to recover, even from the worst scenarios.

In this environment, Disaster Recovery is delivered by **Veeam Kasten**, which backs up
the whole application, exports it to immutable S3 object storage and restores it on the
DR cluster, adapting it to the target (for example with a different StorageClass).

## Why one does not replace the other

Replication protects against infrastructure failures, but it copies everything instantly,
including mistakes. If ransomware encrypts a volume or an administrator deletes a
namespace, every replica is affected within seconds. Only an independent, point-in-time
copy stored outside the cluster allows the business to go back to a clean state.

On the other hand,