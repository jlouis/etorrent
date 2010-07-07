%% Helper child specs for supervisors
-define(CHILD(I), {I, {I, start_link, []}, permanent, 5000, worker, [I]}).
-define(CHILDP(I, P), {I, {I, start_link, P}, permanent, 5000, worker, [I]}).
-define(CHILDW(I, W), {I, {I, start_link, []}, permanent, W, worker, [I]}).
