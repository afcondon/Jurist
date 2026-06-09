// Fetch + parse the trajectory JSON. Shape matches the `Trajectory` record
// (extra fields are harmless). EffectFnAff form: (onError, onSuccess) => canceler.
export const loadTrajectory_ = (url) => (onError, onSuccess) => {
  fetch(url)
    .then((r) => {
      if (!r.ok) throw new Error("HTTP " + r.status + " fetching " + url);
      return r.json();
    })
    .then((d) => onSuccess(d))
    .catch((e) => onError(e));
  return (cancelError, onCancelerError, onCancelerSuccess) => onCancelerSuccess();
};
