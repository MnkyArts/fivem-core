// Storybook 10 for the core NUI shell (Vue 3 + Vite).
// controls / actions / interactions / backgrounds / viewport ship inside `storybook` itself
// in 10.x, so `@storybook/addon-docs` (MDX pages + autodocs) is the only extra Storybook
// package. `remark-gfm` comes with it because addon-docs 10.6 compiles MDX WITHOUT GitHub
// tables — the protocol pages in src/stories/docs are mostly tables, and they render as one
// run-on paragraph without this plugin.
// `docgen` is left at its default on purpose: `vue-component-meta` would pull in a
// `typescript` install this package does not have.
// The app's vite.config.js is picked up automatically (that is where @vitejs/plugin-vue
// lives); builder-vite drops its `build` block, so `outDir: '../html'` cannot be touched.
// `.storybook/manager.js` adds the custom "Lua" panel (see .storybook/lua-panel.js).
import remarkGfm from 'remark-gfm'

/** @type {import('@storybook/vue3-vite').StorybookConfig} */
export default {
  framework: { name: '@storybook/vue3-vite', options: {} },
  addons: [
    {
      name: '@storybook/addon-docs',
      options: { mdxPluginOptions: { mdxCompileOptions: { remarkPlugins: [remarkGfm] } } },
    },
  ],
  stories: ['../src/**/*.mdx', '../src/**/*.stories.js'],
}
