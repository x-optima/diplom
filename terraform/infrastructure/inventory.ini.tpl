[master]
master-1 ansible_host=${master_external} ansible_user=${vm_user} ansible_host_internal=${master_internal} ansible_ssh_common_args='-o StrictHostKeyChecking=no'

# Рабочие машины подключаются через управляющую машину по внутренним
# адресам: отдельный внешний доступ по SSH к каждой из них не нужен.
[workers]
%{ for index, worker in workers ~}
worker-${index + 1} ansible_host=${worker.internal} ansible_user=${vm_user} ansible_host_internal=${worker.internal} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ~/.ssh/yandex -o StrictHostKeyChecking=no -W %h:%p ${vm_user}@${master_external}"'
%{ endfor ~}

[k8s_cluster:children]
master
workers

[all:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=~/.ssh/yandex
