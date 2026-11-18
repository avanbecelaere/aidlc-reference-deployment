# Performance Test Instructions

**Not applicable, by scope.** Vision §5 rules out autoscaling and monitoring, and the requirements set no performance target. The service returns a constant from one 0.25 vCPU task to one operator address. A load test would measure nginx, not this system, and it would have to come from the single allowed address.

The only timing that matters in the demo is how long a deploy takes, which shows in each workflow run's duration. The target is under about 5 minutes, and teardown takes about 2 to 3 minutes.
