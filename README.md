# Onboarding
# Automated User Onboarding

This repository automates new user creation in on-premises Active Directory (AD) by processing onboarding messages from an AWS SQS queue.  
It supports template-based cloning, group assignments, and post-sync processing for cloud group memberships.



## Overview

This system enables hybrid cloud onboarding without human intervention:

1. A new hire submission (via form) generates a message in AWS SQS
2. The Poller PowerShell script running on a domain-joined EC2 instance:
   - Polls SQS for new user requests
   - Clones a template AD user
   - Creates a new AD user in the same OU as the template
   - Adds the user to appropriate on-prem AD groups
   - Appends the new user’s info to `NewHires.csv` for post-sync processing
3. After AD syncs to Azure AD, an optional post-sync script assigns cloud-only groups 


