#!/usr/bin/env bash
# Tenta criar uma VM Always Free (Ampere A1, 2 OCPUs, 12 GB, Ubuntu 24.04).
# Saída 0 = VM já existe ou foi criada. Saída 1 = sem capacidade agora (tenta de novo no próximo ciclo).
set -uo pipefail

NOME="vm-pessoal"
SHAPE="VM.Standard.A1.Flex"
COMPARTIMENTO="$OCI_TENANCY_OCID"

# 1. Se já existe uma A1 ativa ou sendo criada, não faz nada (evita passar do limite free).
EXISTENTES=$(oci compute instance list --compartment-id "$COMPARTIMENTO" --all \
  --query "length(data[?shape=='$SHAPE' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
  --raw-output)
if [ "${EXISTENTES:-0}" -gt 0 ]; then
  echo "Já existe VM A1 na conta. Nada a fazer."
  exit 0
fi

# 2. Imagem mais recente do Ubuntu 24.04 para ARM.
IMAGEM=$(oci compute image list --compartment-id "$COMPARTIMENTO" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 \
  --query 'data[0].id' --raw-output)

echo "$SSH_PUBLIC_KEY" > /tmp/chave.pub

# 3. Tenta em cada availability domain da região.
for AD in $(oci iam availability-domain list --compartment-id "$COMPARTIMENTO" --query 'data[].name' --raw-output | tr -d '[]",'); do
  echo "Tentando em $AD..."
  if SAIDA=$(oci compute instance launch \
      --compartment-id "$COMPARTIMENTO" \
      --availability-domain "$AD" \
      --display-name "$NOME" \
      --shape "$SHAPE" \
      --shape-config '{"ocpus":2,"memoryInGBs":12}' \
      --image-id "$IMAGEM" \
      --subnet-id "$OCI_SUBNET_ID" \
      --assign-public-ip true \
      --ssh-authorized-keys-file /tmp/chave.pub 2>&1); then
    echo "VM criada com sucesso!"
    exit 0
  fi
  echo "$SAIDA" | grep -oE '"message": "[^"]*"' | head -1
done

echo "Sem capacidade agora. Nova tentativa no próximo ciclo."
exit 1
