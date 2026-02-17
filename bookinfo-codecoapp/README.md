# Bookinfo CodecoApp (kube-burner)

This folder runs Bookinfo as `CodecoApp` objects via kube-burner.

## Files
- `run_experiment_bookinfo_microservices.sh`: main runner (`qos` or `def`)
- `kubelet-density-heavy.bookinfo.template.yml`: kube-burner template
- `bookinfo-microservices-qos.yml`: QoS scheduler `CodecoApp` template
- `bookinfo-microservices-def.yml`: default scheduler `CodecoApp` template
