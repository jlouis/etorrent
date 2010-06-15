This is stolen totally from git by Junio C. Hamano. I like it,
so this is how we rock the main repository.

The policy.

 - Feature releases are numbered as vX.Y and are meant to
   contain bugfixes and enhancements in any area, including
   functionality, performance and usability, without regression.

 - Maintenance releases are numbered as vX.Y.W and are meant
   to contain only bugfixes for the corresponding vX.Y feature
   release and earlier maintenance releases vX.Y.V (V < W).

 - 'master' branch is used to prepare for the next feature
   release. In other words, at some point, the tip of 'master'
   branch is tagged with vX.Y.

 - 'maint' branch is used to prepare for the next maintenance
   release.  After the feature release vX.Y is made, the tip
   of 'maint' branch is set to that release, and bugfixes will
   accumulate on the branch, and at some point, the tip of the
   branch is tagged with vX.Y.1, vX.Y.2, and so on.

 - 'next' branch is used to publish changes (both enhancements
   and fixes) that (1) have worthwhile goal, (2) are in a fairly
   good shape suitable for everyday use, (3) but have not yet
   demonstrated to be regression free.  New changes are tested
   in 'next' before merged to 'master'.

 - 'pu' branch is used to publish other proposed changes that do
   not yet pass the criteria set for 'next'.

 - The tips of 'master', 'maint' and 'next' branches will always
   fast forward, to allow people to build their own
   customization on top of them.

 - Usually 'master' contains all of 'maint', 'next' contains all
   of 'master' and 'pu' contains all of 'next'.

 - The tip of 'master' is meant to be more stable than any
   tagged releases, and the users are encouraged to follow it.

 - The 'next' branch is where new action takes place, and the
   users are encouraged to test it so that regressions and bugs
   are found before new topics are merged to 'master'.
