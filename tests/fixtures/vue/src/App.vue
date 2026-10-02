<template>
  <h1>{{ $t('common.title') }}</h1>
  <button>{{ t("common.actions.save") }}</button> <span>{{ t('home.title') }}</span>
  <p>{{ t(`dynamic.${key}`) }}</p>
  <p>{{ test('not.a.call') }} {{ t('missing.key') }}</p>
</template>
<script setup lang="ts">
const label = i18n.global.t('common.actions.cancel')
const ok = te('common.title')
</script>
