#!/usr/bin/env bash
# Consegue uma VM Always Free (Ampere A1, Ubuntu 24.04) chegando a 2 OCPUs / 12 GB.
#   - Sem VM: tenta 2/12; sem vaga, tenta 1/6 (que depois é aumentada).
#   - VM 1/6 existente: tenta aumentar para 2/12 (reinicia a VM ~1 min).
# Saída 0 = VM 2/12 pronta (para de tentar). Saída 1 = ainda não (tenta de novo no próximo ciclo).
set -uo pipefail

NOME="vm-pessoal"
SHAPE="VM.Standard.A1.Flex"
COMPARTIMENTO="$OCI_TENANCY_OCID"
GRANDE='{"ocpus":2,"memoryInGBs":12}'
PEQUENA='{"ocpus":1,"memoryInGBs":6}'

# 1. Já existe A1 na conta? Nunca cria uma segunda (evita passar do limite free).
VM_ID=$(oci compute instance list --compartment-id "$COMPARTIMENTO" --all \
  --query "data[?shape=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
  --raw-output)

if [ -n "$VM_ID" ] && [ "$VM_ID" != "null" ]; then
  ESTADO=$(oci compute instance get --instance-id "$VM_ID" --query 'data."lifecycle-state"' --raw-output)
  OCPUS=$(oci compute instance get --instance-id "$VM_ID" --query 'data."shape-config".ocpus' --raw-output | cut -d. -f1)
  echo "VM existente: estado=$ESTADO, OCPUs=$OCPUS"

  if [ "${OCPUS:-0}" -ge 2 ]; then
    echo "VM já tem 2 OCPUs / 12 GB. Nada a fazer."
    exit 0
  fi
  if [ "$ESTADO" != "RUNNING" ] && [ "$ESTADO" != "STOPPED" ]; then
    echo "VM em $ESTADO; tenta aumentar no próximo ciclo."
    exit 1
  fi

  echo "Tentando aumentar para 2/12..."
  if SAIDA=$(oci compute instance update --instance-id "$VM_ID" \
      --shape-config "$GRANDE" --force \
      --wait-for-state RUNNING --wait-for-state STOPPED --max-wait-seconds 900 2>&1); then
    NOVO=$(oci compute instance get --instance-id "$VM_ID" --query 'data."shape-config".ocpus' --raw-output | cut -d. -f1)
    if [ "${NOVO:-0}" -ge 2 ]; then
      echo "VM aumentada para 2 OCPUs / 12 GB!"
      exit 0
    fi
  fi
  echo "$SAIDA" | grep -oE '"message": "[^"]*"' | head -1
  echo "Ainda sem vaga para aumentar. Nova tentativa no próximo ciclo."
  exit 1
fi

# 2. Imagem mais recente do Ubuntu 24.04 para ARM.
IMAGEM=$(oci compute image list --compartment-id "$COMPARTIMENTO" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 \
  --query 'data[0].id' --raw-output)

echo "$SSH_PUBLIC_KEY" > /tmp/chave.pub

# 3. Tenta em cada availability domain: primeiro 2/12, depois 1/6.
for AD in $(oci iam availability-domain list --compartment-id "$COMPARTIMENTO" --query 'data[].name' --raw-output | tr -d '[]",'); do
  for TAMANHO in "$GRANDE" "$PEQUENA"; do
    echo "Tentando $TAMANHO em $AD..."
    if SAIDA=$(oci compute instance launch \
        --compartment-id "$COMPARTIMENTO" \
        --availability-domain "$AD" \
        --display-name "$NOME" \
        --shape "$SHAPE" \
        --shape-config "$TAMANHO" \
        --image-id "$IMAGEM" \
        --subnet-id "$OCI_SUBNET_ID" \
        --assign-public-ip true \
        --ssh-authorized-keys-file /tmp/chave.pub 2>&1); then
      if [ "$TAMANHO" = "$GRANDE" ]; then
        echo "VM 2/12 criada com sucesso!"
        exit 0
      fi
      echo "VM 1/6 criada! Próximos ciclos tentam aumentar para 2/12."
      exit 1
    fi
    echo "$SAIDA" | grep -oE '"message": "[^"]*"' | head -1
  done
done

echo "Sem capacidade agora. Nova tentativa no próximo ciclo."
exit 1
